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
/// the second one silently never fires — so both "Import Pairing File" and
/// "Import Bookmarks" route through this single piece of state and a single
/// `.fileImporter` modifier below.
private enum PendingImport: Identifiable {
    case pairingFile
    case bookmarks

    var id: Int {
        switch self {
        case .pairingFile: return 0
        case .bookmarks: return 1
        }
    }

    var allowedContentTypes: [UTType] {
        switch self {
        case .pairingFile: return PairingFileStore.supportedContentTypes
        case .bookmarks: return [.json]
        }
    }
}

struct SettingsView: View {
    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @AppStorage(UserDefaults.Keys.targetDeviceIP) private var targetDeviceIP = DeviceConnectionContext.defaultTargetIPAddress

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
    /// Stamped when Export is tapped rather than computed in `body`, which would
    /// rebuild a `DateFormatter` on every render.
    @State private var bookmarkExportFilename = ""
    @State private var bookmarkMessage: (text: String, isError: Bool)?

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
                    Toggle(isOn: $keepAliveAudio) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Silent Audio")
                            Text("Plays inaudible audio so iOS keeps the app running.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: keepAliveAudio) { _, enabled in
                        if enabled { BackgroundAudioManager.shared.start() }
                        else { BackgroundAudioManager.shared.stop() }
                    }

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

                Section("Bookmarks") {
                    Text(bookmarkCountText)
                        .foregroundStyle(bookmarks.isEmpty ? .secondary : .primary)

                    Button {
                        exportBookmarksPressed()
                    } label: {
                        Label("Export Bookmarks", systemImage: "square.and.arrow.up")
                    }
                    .foregroundStyle(.primary)
                    .disabled(bookmarks.isEmpty)

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
            .onAppear { bookmarks = BookmarkStore.load() }
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
                    case .success:
                        bookmarkMessage = ("Exported \(bookmarks.count) \(bookmarks.count == 1 ? "bookmark" : "bookmarks").", false)
                    case .failure(let error):
                        bookmarkMessage = ("Export failed: \(error.localizedDescription)", true)
                    }
                    scheduleBookmarkStatusDismiss()
                }
        )
        // Single consolidated importer for both "Import Pairing File" /
        // "Replace Pairing File" and "Import Bookmarks" — see `PendingImport`.
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
                pairingImportMessage = ("Imported successfully", false)
                startTunnelInBackground()
                schedulePairingStatusDismiss()
            } catch {
                isImportingFile = false
                pairingImportMessage = ("Import failed: \(error.localizedDescription)", true)
                schedulePairingStatusDismiss()
            }
        case .failure(let error):
            isImportingFile = false
            pairingImportMessage = ("Import failed: \(error.localizedDescription)", true)
            schedulePairingStatusDismiss()
        }
    }

    // MARK: - Bookmarks

    private var bookmarkCountText: String {
        switch bookmarks.count {
        case 0: return "No saved locations"
        case 1: return "1 saved location"
        default: return "\(bookmarks.count) saved locations"
        }
    }

    private func exportBookmarksPressed() {
        bookmarkMessage = nil
        // Re-read rather than trusting the cached copy: the map may have added
        // a bookmark since this sheet was opened.
        bookmarks = BookmarkStore.load()
        guard !bookmarks.isEmpty else { return }

        do {
            bookmarkExportDocument = BookmarksDocument(data: try BookmarkStore.exportData(bookmarks))
            bookmarkExportFilename = BookmarkStore.exportFileName()
            isShowingBookmarkExporter = true
        } catch {
            bookmarkMessage = ("Export failed: \(error.localizedDescription)", true)
            scheduleBookmarkStatusDismiss()
        }
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
                    bookmarkMessage = ("That file contains no bookmarks.", false)
                } else if merge.skipped == 0 {
                    bookmarkMessage = ("Imported \(merge.added) \(merge.added == 1 ? "bookmark" : "bookmarks").", false)
                } else {
                    bookmarkMessage = ("Imported \(merge.added), skipped \(merge.skipped) already saved.", false)
                }
            } catch {
                bookmarkMessage = ("Import failed: the file is not a valid TLocation bookmarks file.", true)
            }
        case .failure(let error):
            bookmarkMessage = ("Import failed: \(error.localizedDescription)", true)
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
                ddiStatusMessage = "Preparing download…"
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
                    ddiResultMessage = ("DDI files refreshed successfully.", false)
                }
            } catch {
                await MainActor.run {
                    isRedownloadingDDI = false
                    ddiResultMessage = ("Failed to redownload DDI files: \(error.localizedDescription)", true)
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
