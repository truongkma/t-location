//
//  SettingsView.swift
//  TLocation
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum SettingsLinks {
    static let pairingFileGuide = URL(string: "https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md")!
    static let localDevVPN = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
}

/// Wraps the encoded bookmark JSON for `.fileExporter`, which hands the user the
/// system save sheet (Files, iCloud Drive, and anything else with a document
/// provider). Read-only: the export never round-trips back through this type.
private struct BookmarksDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Which file picker is currently requested. SwiftUI only reliably presents one
/// `.fileImporter` per view — stacking two at the same modifier-chain level means
/// the second one silently never fires — so "Import Pairing File", "Import
/// Bookmarks" and "Link Sync File" all route through this single piece of state
/// and a single `.fileImporter` modifier below.
private enum PendingImport: Identifiable {
    case pairingFile
    case bookmarks
    case bookmarkSyncFile

    var id: Int {
        switch self {
        case .pairingFile: return 0
        case .bookmarks: return 1
        case .bookmarkSyncFile: return 2
        }
    }

    var allowedContentTypes: [UTType] {
        switch self {
        case .pairingFile: return PairingFileStore.supportedContentTypes
        case .bookmarks, .bookmarkSyncFile: return [.json]
        }
    }
}

/// File-scope so it is built once rather than on every render of the sync rows.
private let syncTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter
}()

struct SettingsView: View {
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @AppStorage(UserDefaults.Keys.targetDeviceIP) private var targetDeviceIP = DeviceConnectionContext.defaultTargetIPAddress
    /// Off by default — the user must opt in. Read live by the resend loop in
    /// `LocationSimulationView`, so this only ever affects the periodic resends
    /// of an already-active simulation, never the initial "Simulate Location"
    /// call, the pin, or anything else shown on screen.
    @AppStorage("naturalGPSDrift") private var naturalGPSDrift = false

    /// Mirrors `LanguageSettings.selected`; the `onChange` below is what writes
    /// the matching `AppleLanguages` override.
    @State private var selectedLanguage = LanguageSettings.selected
    /// True once the stored choice differs from the one this process launched
    /// with — i.e. only when reopening the app would actually change something.
    @State private var languageNeedsRestart = LanguageSettings.selected != LanguageSettings.activeAtLaunch

    @State private var isImportingFile = false
    /// Cheap existence check only — `prepareURL()` does directory creation and a
    /// full byte-compare, which has no business running while a view body renders.
    @State private var pairingFileExists = FileManager.default.fileExists(
        atPath: PairingFileStore.url.path
    )
    @State private var pairingImportMessage: (text: String, isError: Bool)?
    /// Drives the single consolidated `.fileImporter` below — see `PendingImport`.
    @State private var pendingImport: PendingImport?
    @State private var showDDIConfirmation = false
    @State private var isRedownloadingDDI = false
    @State private var ddiDownloadProgress: Double = 0.0
    @State private var ddiStatusMessage: String = ""
    @State private var ddiResultMessage: (text: String, isError: Bool)?

    // Bookmarks. Loaded once when the sheet appears and kept in step with every
    // import, so the count row never lies about what is in the store.
    @State private var bookmarks: [LocationBookmark] = []
    @State private var isShowingBookmarkExporter = false
    @State private var bookmarkExportDocument: BookmarksDocument?
    /// Stamped when Create Sync File is tapped rather than computed in `body`,
    /// which would rebuild a `DateFormatter` on every render.
    @State private var bookmarkExportFilename = ""
    @State private var bookmarkMessage: (text: String, isError: Bool)?

    // Linked sync file. A singleton that outlives this sheet, so `@ObservedObject`
    // rather than `@StateObject`: this view watches it, it does not own it.
    @ObservedObject private var syncFile = BookmarkSyncFile.shared
    @State private var isSyncing = false
    @State private var syncMessage: (text: String, isError: Bool)?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Red once the signature has lapsed, orange inside the last day, otherwise
    /// the same muted grey as every other detail value in this form.
    private var signingExpiryColor: Color {
        if AppSigningInfo.hasExpired { return .red }
        return AppSigningInfo.isExpiringSoon ? .orange : .secondary
    }

    var body: some View {
        NavigationStack {
            Form {
                languageSection

                Section("Pairing File") {
                    if pairingFileExists {
                        Label("Pairing file imported", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    Button {
                        pendingImport = .pairingFile
                    } label: {
                        Label("Import Pairing File", systemImage: "doc.badge.plus")
                    }
                    .disabled(isImportingFile || pairingFileExists)

                    // A pairing file expires, so replacing one must stay possible.
                    // Deliberately secondary: the prominent action above is
                    // disabled once a file is in place, and this is the way back.
                    if pairingFileExists {
                        Button("Replace Pairing File") {
                            pendingImport = .pairingFile
                        }
                        .buttonStyle(.plain)
                        .font(.footnote)
                        .foregroundStyle(.tint)
                        .disabled(isImportingFile)
                    }

                    if isImportingFile {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Importing pairing file…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let pairingImportMessage {
                        Label(
                            pairingImportMessage.text,
                            systemImage: pairingImportMessage.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(pairingImportMessage.isError ? .red : .green)
                    }
                }

                Section("Background Keep-Alive") {
                    Toggle(isOn: $keepAliveLocation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Background Location")
                            Text("Uses low-accuracy location to stay alive while simulating.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: keepAliveLocation) { _, enabled in
                        if !enabled { BackgroundLocationManager.shared.stop() }
                    }
                }

                Section("Simulation") {
                    Toggle(isOn: $naturalGPSDrift) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Natural GPS Drift")
                            Text("Adds a few metres of random movement so the simulated position looks like a real GPS fix.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Bookmarks") {
                    Text(bookmarkCountText)
                        .foregroundStyle(bookmarks.isEmpty ? .secondary : .primary)

                    Button {
                        bookmarkMessage = nil
                        pendingImport = .bookmarks
                    } label: {
                        Label("Import Bookmarks", systemImage: "square.and.arrow.down")
                    }
                    .foregroundStyle(.primary)

                    if let bookmarkMessage {
                        Label(
                            bookmarkMessage.text,
                            systemImage: bookmarkMessage.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(bookmarkMessage.isError ? .red : .green)
                    } else {
                        Text("Exported bookmarks are saved as a JSON file you can keep in Files or iCloud Drive and import again after reinstalling.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                bookmarkSyncSection

                Section("Advanced") {
                    // Omitted entirely when there is no embedded provisioning profile
                    // to read — an App Store or TrollStore install has no expiry.
                    if let expiry = AppSigningInfo.formattedExpirationDate,
                       let remaining = AppSigningInfo.remainingPhrase {
                        HStack {
                            Text("Signing expires")
                            Spacer()
                            Text("\(expiry) (\(remaining))")
                                .foregroundStyle(signingExpiryColor)
                        }
                    }

                    HStack {
                        Text("Target Device IP")
                        Spacer()
                        TextField(DeviceConnectionContext.defaultTargetIPAddress, text: $targetDeviceIP)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.numbersAndPunctuation)
                            .frame(maxWidth: 160)
                    }
                    Button { showDDIConfirmation = true } label: {
                        Label("Redownload DDI", systemImage: "arrow.down.circle")
                    }
                    .foregroundStyle(.primary)
                    .disabled(isRedownloadingDDI)

                    if isRedownloadingDDI {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: ddiDownloadProgress, total: 1.0)
                            Text(ddiStatusMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let result = ddiResultMessage {
                        Text(result.text).font(.caption).foregroundStyle(result.isError ? .red : .green)
                    }
                }

                Section("Help") {
                    Link(destination: SettingsLinks.pairingFileGuide) {
                        Label("Pairing File Guide", systemImage: "questionmark.circle")
                    }
                    Link(destination: SettingsLinks.localDevVPN) {
                        Label("Download LocalDevVPN", systemImage: "arrow.down.circle")
                    }
                }

                Section {
                    Text("TLocation \(appVersion) • iOS \(UIDevice.current.systemVersion)")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                bookmarks = BookmarkStore.load()
                // Confirms the linked file is still where it was, so a file
                // deleted or moved since the last launch is reported here
                // rather than only after the next failed write.
                syncFile.refresh()
            }
        }
        // The exporter lives on its own invisible subview (rather than chained
        // directly alongside the importer below) so its presentation trigger has
        // its own view identity — the same modifier-conflict class of bug that
        // broke the two stacked `.fileImporter`s can bite an exporter mixed in
        // with an importer at the same level, and this sidesteps it entirely.
        .background(
            Color.clear
                .fileExporter(
                    isPresented: $isShowingBookmarkExporter,
                    document: bookmarkExportDocument,
                    contentType: .json,
                    defaultFilename: bookmarkExportFilename
                ) { result in
                    switch result {
                    case .success(let url):
                        // The save sheet has already written the bookmarks
                        // into the new file; linking it records the URL
                        // bookmark and reconciles the two sides.
                        linkSyncFile(at: url, wasJustCreated: true)
                    case .failure(let error):
                        // Cancelling the save sheet reports itself as a failure.
                        // It is not one, and saying "Could not create a sync
                        // file" for a deliberate Cancel would be nonsense.
                        guard !isUserCancellation(error) else { return }
                        let detail = error.localizedDescription
                        syncMessage = (String(localized: "Could not create a sync file: \(detail)"), true)
                        scheduleSyncStatusDismiss()
                    }
                }
        )
        // Single consolidated importer for "Import Pairing File" / "Replace
        // Pairing File", "Import Bookmarks" and "Link Sync File" — see
        // `PendingImport`. Adding a fourth caller means a fourth enum case, not
        // a second `.fileImporter`.
        // `isPresented` derives from `pendingImport`, and clears it on dismiss
        // (including cancel, which never invokes the completion closure) so a
        // stale non-nil `pendingImport` can never block the next tap.
        .fileImporter(
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { isPresented in if !isPresented { pendingImport = nil } }
            ),
            allowedContentTypes: pendingImport?.allowedContentTypes ?? PairingFileStore.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            let requested = pendingImport
            pendingImport = nil
            switch requested {
            case .bookmarks:
                importBookmarks(from: result)
            case .bookmarkSyncFile:
                linkSyncFile(from: result)
            case .pairingFile:
                importPairingFile(from: result)
            case nil:
                break
            }
        }
        .confirmationDialog("Redownload DDI Files?", isPresented: $showDDIConfirmation, titleVisibility: .visible) {
            Button("Redownload", role: .destructive) { redownloadDDIPressed() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Existing DDI files will be removed before downloading fresh copies.")
        }
    }

    // MARK: - Language Section

    /// Forces the app's language regardless of the device setting. See
    /// `LanguageSettings` for why this only takes effect on the next launch —
    /// the footer says so, because a control that looks instant and is not
    /// would be worse than no control at all.
    @ViewBuilder
    private var languageSection: some View {
        Section("Language") {
            Picker("Language", selection: $selectedLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    if let endonym = language.endonym {
                        // Language names are shown in their own language, so
                        // they are deliberately not translated.
                        Text(verbatim: endonym).tag(language)
                    } else {
                        Text("System").tag(language)
                    }
                }
            }
            .pickerStyle(.menu)
            .onChange(of: selectedLanguage) { _, language in
                LanguageSettings.apply(language)
                languageNeedsRestart = language != LanguageSettings.activeAtLaunch
            }

            if languageNeedsRestart {
                Label(
                    "Close and reopen TLocation to switch language.",
                    systemImage: "arrow.clockwise.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else {
                Text("The new language is applied the next time you open TLocation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sync File Section

    /// A linked JSON file that TLocation rewrites on every bookmark change.
    /// Deliberately its own section: it is a standing arrangement, unlike the
    /// one-shot Export and Import above it.
    @ViewBuilder
    private var bookmarkSyncSection: some View {
        Section("Bookmark Sync File") {
            if let fileName = syncFile.status.fileName {
                HStack {
                    Text("Linked File")
                    Spacer()
                    Text(fileName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let failure = syncFile.status.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let lastSyncedAt = syncFile.status.lastSyncedAt {
                    HStack {
                        Text("Last Synced")
                        Spacer()
                        Text(syncTimestampFormatter.string(from: lastSyncedAt))
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    syncNowPressed()
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .foregroundStyle(.primary)
                .disabled(isSyncing)

                Button(role: .destructive) {
                    unlinkSyncFilePressed()
                } label: {
                    Label("Unlink Sync File", systemImage: "xmark.circle")
                }
                .disabled(isSyncing)
            } else {
                Button {
                    syncMessage = nil
                    pendingImport = .bookmarkSyncFile
                } label: {
                    Label("Link Sync File", systemImage: "link")
                }
                .foregroundStyle(.primary)
                .disabled(isSyncing)

                Button {
                    createSyncFilePressed()
                } label: {
                    Label("Create Sync File", systemImage: "doc.badge.plus")
                }
                .foregroundStyle(.primary)
                .disabled(isSyncing)
            }

            if isSyncing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Syncing bookmarks…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let syncMessage {
                Label(
                    syncMessage.text,
                    systemImage: syncMessage.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(syncMessage.isError ? .red : .green)
            } else if syncFile.status.isLinked {
                Text("Bookmarks are written to this file whenever they change. Link the same file on another device to share them.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Link a JSON file — one kept in iCloud Drive works well — and TLocation keeps it up to date, so your bookmarks survive reinstalling the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sync File Actions

    private func createSyncFilePressed() {
        syncMessage = nil
        bookmarks = BookmarkStore.load()
        do {
            bookmarkExportDocument = BookmarksDocument(data: try BookmarkStore.exportData(bookmarks))
            bookmarkExportFilename = BookmarkStore.syncFileName
            isShowingBookmarkExporter = true
        } catch {
            let detail = error.localizedDescription
            syncMessage = (String(localized: "Could not create a sync file: \(detail)"), true)
            scheduleSyncStatusDismiss()
        }
    }

    private func linkSyncFile(from result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            linkSyncFile(at: url)
        case .failure(let error):
            guard !isUserCancellation(error) else { return }
            let detail = error.localizedDescription
            syncMessage = (String(localized: "Could not link that file: \(detail)"), true)
            scheduleSyncStatusDismiss()
        }
    }

    private func isUserCancellation(_ error: Error) -> Bool {
        (error as? CocoaError)?.code == .userCancelled
    }

    /// Shared by "Link Sync File" (a file the picker returned) and "Create Sync
    /// File" (a file the save sheet just wrote). Both hand back a URL that is
    /// security scoped for as long as this call runs, which is when
    /// `BookmarkSyncFile` has to mint its bookmark data.
    ///
    /// `wasJustCreated` only changes the failure wording: a file that was just
    /// written but could not be linked is a state the user can recover from by
    /// picking it, and the message has to say so rather than leave them
    /// wondering whether the file exists.
    private func linkSyncFile(at url: URL, wasJustCreated: Bool = false) {
        syncMessage = nil
        isSyncing = true
        // Opened here, synchronously inside the picker's completion, and held
        // for the whole async link so the sandbox extension cannot be reclaimed
        // while the work is still in flight. `BookmarkSyncFile` opens its own
        // nested scope; start/stop calls are reference counted.
        let accessing = url.startAccessingSecurityScopedResource()
        Task {
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let outcome = try await BookmarkSyncFile.shared.link(to: url)
                syncMessage = (linkSummary(outcome), false)
            } catch {
                let detail = error.localizedDescription
                syncMessage = wasJustCreated
                    ? (String(localized: "The file was saved, but TLocation could not link it. Tap Link Sync File and choose it."), true)
                    : (String(localized: "Could not link that file: \(detail)"), true)
            }
            // Reloaded on both paths: a link that failed part-way may still have
            // merged the file's contents into the local list, and the count row
            // above must not go stale.
            bookmarks = BookmarkStore.load()
            isSyncing = false
            scheduleSyncStatusDismiss()
        }
    }

    private func syncNowPressed() {
        syncMessage = nil
        isSyncing = true
        Task {
            do {
                let outcome = try await BookmarkSyncFile.shared.pull()
                syncMessage = (syncSummary(outcome), false)
            } catch {
                let detail = error.localizedDescription
                syncMessage = (String(localized: "Sync failed: \(detail)"), true)
            }
            bookmarks = BookmarkStore.load()
            isSyncing = false
            scheduleSyncStatusDismiss()
        }
    }

    private func unlinkSyncFilePressed() {
        BookmarkSyncFile.shared.unlink()
        syncMessage = (String(localized: "Sync file unlinked. The file itself was not deleted."), false)
        scheduleSyncStatusDismiss()
    }

    // Whole sentences per case rather than assembled fragments, so a translator
    // gets a complete string to work with.

    private func linkSummary(_ outcome: BookmarkSyncFile.SyncOutcome) -> String {
        let name = outcome.fileName
        if outcome.added == 0 {
            return String(localized: "Linked “\(name)”.")
        }
        if outcome.skipped == 0 {
            return String(localized: "Linked “\(name)”. Added \(outcome.added) saved locations from the file.")
        }
        return String(localized: "Linked “\(name)”. Added \(outcome.added), skipped \(outcome.skipped) already saved.")
    }

    private func syncSummary(_ outcome: BookmarkSyncFile.SyncOutcome) -> String {
        if outcome.added == 0 && outcome.skipped == 0 {
            return String(localized: "Synced. The file had nothing new.")
        }
        if outcome.skipped == 0 {
            return String(localized: "Synced. Added \(outcome.added) saved locations.")
        }
        return String(localized: "Synced. Added \(outcome.added), skipped \(outcome.skipped) already saved.")
    }

    /// Same self-cancelling pattern as `scheduleBookmarkStatusDismiss`: only
    /// clears the line if it still shows the message this call scheduled.
    private func scheduleSyncStatusDismiss() {
        let pending = syncMessage?.text
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                if syncMessage?.text == pending { syncMessage = nil }
            }
        }
    }

    // MARK: - Pairing File

    private func importPairingFile(from result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isImportingFile = true
            pairingImportMessage = nil
            do {
                try PairingFileStore.importFromPicker(url)
                isImportingFile = false
                pairingFileExists = true
                LogManager.shared.addInfoLog("Pairing file imported from \(url.lastPathComponent)")
                pairingImportMessage = (String(localized: "Imported successfully"), false)
                startTunnelInBackground()
                schedulePairingStatusDismiss()
            } catch {
                isImportingFile = false
                let detail = error.localizedDescription
                LogManager.shared.addErrorLog("Pairing file import failed for \(url.lastPathComponent): \(detail)")
                pairingImportMessage = (String(localized: "Import failed: \(detail)"), true)
                schedulePairingStatusDismiss()
            }
        case .failure(let error):
            isImportingFile = false
            let detail = error.localizedDescription
            LogManager.shared.addErrorLog("Pairing file picker failed: \(detail)")
            pairingImportMessage = (String(localized: "Import failed: \(detail)"), true)
            schedulePairingStatusDismiss()
        }
    }

    // MARK: - Bookmarks

    /// "No saved locations" is its own string rather than the zero case of the
    /// plural one: English wants words there, not a digit.
    private var bookmarkCountText: String {
        bookmarks.isEmpty
            ? String(localized: "No saved locations")
            : String(localized: "\(bookmarks.count) saved locations")
    }

    /// Merges the picked file into the saved list. Nothing already saved is ever
    /// removed, and any failure surfaces as a message in the section rather than
    /// as silence or a crash.
    private func importBookmarks(from result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            do {
                let imported = try BookmarkStore.decode(try Data(contentsOf: url))
                let merge = BookmarkStore.merge(imported, into: BookmarkStore.load())
                BookmarkStore.save(merge.bookmarks)
                bookmarks = merge.bookmarks

                if merge.added == 0 && merge.skipped == 0 {
                    bookmarkMessage = (String(localized: "That file contains no saved locations."), false)
                } else if merge.skipped == 0 {
                    bookmarkMessage = (String(localized: "Imported \(merge.added) saved locations."), false)
                } else {
                    bookmarkMessage = (String(localized: "Imported \(merge.added), skipped \(merge.skipped) already saved."), false)
                }
            } catch {
                bookmarkMessage = (String(localized: "Import failed: the file is not a valid TLocation bookmarks file."), true)
            }
        case .failure(let error):
            let detail = error.localizedDescription
            bookmarkMessage = (String(localized: "Import failed: \(detail)"), true)
        }
        scheduleBookmarkStatusDismiss()
    }

    /// Clears the status line after a few seconds, but only if it still shows
    /// the message this call was scheduled for — a second import landing in the
    /// meantime keeps its own full window.
    private func scheduleBookmarkStatusDismiss() {
        let pending = bookmarkMessage?.text
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                if bookmarkMessage?.text == pending { bookmarkMessage = nil }
            }
        }
    }

    private func redownloadDDIPressed() {
        guard !isRedownloadingDDI else { return }
        Task {
            await MainActor.run {
                isRedownloadingDDI = true
                ddiDownloadProgress = 0
                ddiStatusMessage = String(localized: "Preparing download…")
                ddiResultMessage = nil
            }
            do {
                try await redownloadDDI { progress, status in
                    Task { @MainActor in
                        self.ddiDownloadProgress = progress
                        self.ddiStatusMessage = status
                    }
                }
                await MainActor.run {
                    isRedownloadingDDI = false
                    ddiResultMessage = (String(localized: "DDI files refreshed successfully."), false)
                }
            } catch {
                let detail = error.localizedDescription
                LogManager.shared.addErrorLog("DDI redownload failed: \(detail)")
                await MainActor.run {
                    isRedownloadingDDI = false
                    ddiResultMessage = (String(localized: "Failed to redownload DDI files: \(detail)"), true)
                }
            }
        }
        scheduleDDIStatusDismiss()
    }

    private func schedulePairingStatusDismiss() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                if !isImportingFile { pairingImportMessage = nil }
            }
        }
    }

    private func scheduleDDIStatusDismiss() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                if !isRedownloadingDDI { ddiResultMessage = nil }
            }
        }
    }
}
