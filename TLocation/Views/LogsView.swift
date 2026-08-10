//
//  LogsView.swift
//  TLocation
//

import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Which entries the list shows.
///
/// Deliberately only two cases. The question someone staring at a failed
/// connection needs answered is "show me everything" or "show me only what
/// went wrong"; a per-level matrix is more control than that question needs
/// and more chrome than a phone-sized screen can spare.
private enum LogLevelFilter: Int, CaseIterable, Identifiable {
    case all
    case problems

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .problems: return "Errors & Warnings"
        }
    }

    func includes(_ type: LogManager.LogEntry.LogType) -> Bool {
        switch self {
        case .all:
            return true
        case .problems:
            return type == .error || type == .warning
        }
    }
}

/// Formats `LogManager`'s entries for the pasteboard and for the shared file.
///
/// Everything this produces is deliberately left untranslated. It is diagnostic
/// text bound for a bug report or a message to whoever is helping, and that
/// reader is not necessarily using the app's language — the same reasoning that
/// keeps the raw FFI messages out of `TunnelManager`'s translated alert body.
enum LogExport {
    /// `en_US_POSIX` throughout: these timestamps are for correlating a
    /// sequence of events, not for presentation, and must not reshuffle
    /// themselves into a 12-hour clock on some devices and not others.
    private static func fixedFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// Time only on screen — the date is in the exported header, and a row on a
    /// phone has no room to repeat it 200 times.
    static let onScreenTimestamp = fixedFormatter("HH:mm:ss.SSS")
    private static let entryTimestamp = fixedFormatter("yyyy-MM-dd HH:mm:ss.SSS")
    private static let fileTimestamp = fixedFormatter("yyyy-MM-dd-HHmmss")

    static func fileName(at date: Date = Date()) -> String {
        "TLocation-log-\(fileTimestamp.string(from: date)).txt"
    }

    /// The header that saves a round trip on every bug report: which build,
    /// which iOS, and whether the three things the app depends on are actually
    /// in place. Reads published state from `TunnelManager` and
    /// `MountingProgress`, so it belongs on the main actor.
    @MainActor
    static func contextHeader(at date: Date = Date()) -> String {
        let bundle = Bundle.main.infoDictionary
        let version = bundle?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle?["CFBundleVersion"] as? String ?? "?"
        let pairingFile = FileManager.default.fileExists(atPath: PairingFileStore.url.path)

        return """
        TLocation diagnostic log
        Exported: \(entryTimestamp.string(from: date))
        App: \(version) (\(build))
        iOS: \(UIDevice.current.systemVersion) on \(deviceModel)
        Pairing file: \(pairingFile ? "present" : "missing")
        Tunnel: \(TunnelManager.shared.isConnected ? "connected" : "not connected")
        DDI: \(MountingProgress.shared.coolisMounted ? "mounted" : "not mounted")
        Target: \(DeviceConnectionContext.targetIPAddress):49152
        """
    }

    /// Header plus every entry, oldest first — the order the list uses, so the
    /// text a reader receives matches the screen the sender was looking at.
    static func document(header: String, entries: [LogManager.LogEntry]) -> String {
        let errorCount = entries.filter { $0.type == .error }.count
        let body = entries
            .map { "[\(entryTimestamp.string(from: $0.timestamp))] \($0.type.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \($0.message)" }
            .joined(separator: "\n")

        return """
        \(header)
        Entries: \(entries.count) (\(errorCount) errors)
        ----------------------------------------
        \(body)
        """
    }

    /// The hardware identifier ("iPhone14,2"), which `UIDevice` does not expose
    /// and which is worth far more in a bug report than "iPhone".
    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return model.isEmpty ? UIDevice.current.model : model
    }
}

/// The log as a shareable plain-text file.
///
/// Holds the entries rather than the finished text so building the document —
/// potentially a thousand lines — happens once, when the user actually picks a
/// share destination, and not on every render of the view that offers it. The
/// context header is captured up front instead, because it reads main-actor
/// state and the export closure does not run on the main actor.
private struct LogArchive: Transferable {
    let header: String
    let entries: [LogManager.LogEntry]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { archive in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(LogExport.fileName())
            try LogExport.document(header: archive.header, entries: archive.entries)
                .write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

/// Rounded backing for the copy-confirmation toast. iOS 26's Liquid Glass where
/// it exists, `.regularMaterial` on iOS 17.4 — the same split as the map's
/// `CalloutBackground`.
private struct ToastBackground: ViewModifier {
    private static let shape = Capsule()

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Self.shape)
                .overlay(Self.shape.strokeBorder(Color.primary.opacity(0.10)))
                .shadow(color: .black.opacity(0.20), radius: 8, y: 4)
        }
    }
}

/// The in-app console for `LogManager`.
///
/// Pushed from Settings, so it deliberately carries no `NavigationStack` of its
/// own, and it adds no `.fileImporter` or `.fileExporter` anywhere: sharing goes
/// through `ShareLink`, which presents its own activity controller and cannot
/// collide with the single importer/exporter pair Settings already owns.
struct LogsView: View {
    /// A singleton that outlives this screen — this view watches it, it does
    /// not own it. Same reasoning as `BookmarkSyncFile` in `SettingsView`.
    @ObservedObject private var logManager = LogManager.shared

    @State private var filter: LogLevelFilter = .all
    @State private var showClearConfirmation = false
    @State private var copyConfirmation: String?

    private var visibleEntries: [LogManager.LogEntry] {
        logManager.logs.filter { filter.includes($0.type) }
    }

    var body: some View {
        Group {
            if logManager.logs.isEmpty {
                ContentUnavailableView(
                    "No Logs",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Nothing has been recorded yet. Connect to the device or simulate a location and the steps will appear here.")
                )
            } else if visibleEntries.isEmpty {
                ContentUnavailableView {
                    Label("No Errors or Warnings", systemImage: "checkmark.circle")
                } description: {
                    Text("Nothing has failed since the log was last cleared.")
                } actions: {
                    Button("Show All") { filter = .all }
                }
            } else {
                entryList
            }
        }
        // Above the list rather than inside it, so it stays put while the rows
        // scroll and remains reachable from the "no matches" state above.
        .safeAreaInset(edge: .top) {
            if !logManager.logs.isEmpty {
                Picker("Filter", selection: $filter) {
                    ForEach(LogLevelFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .overlay(alignment: .bottom) {
            if let copyConfirmation {
                Label(copyConfirmation, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .modifier(ToastBackground())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: copyConfirmation)
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                actionMenu
            }
        }
        .confirmationDialog("Clear Logs?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear Logs", role: .destructive) {
                logManager.clearLogs()
                Haptics.medium()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Every entry will be removed. This cannot be undone.")
        }
    }

    // MARK: - List

    /// `List` rather than a `VStack`: the log runs to a thousand entries and
    /// only the visible rows should ever be built. Oldest first, so reading top
    /// to bottom follows the order things actually happened — startup, tunnel,
    /// mount, whatever failed — which is what diagnosing a sequence needs. The
    /// newest line is therefore at the bottom, and that is where the list opens.
    private var entryList: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(visibleEntries) { entry in
                        row(for: entry)
                            .id(entry.id)
                    }
                } footer: {
                    Text("Copy All and Share always include every entry, even any hidden by the filter above.")
                }
            }
            .listStyle(.plain)
            .onAppear {
                guard let lastID = visibleEntries.last?.id else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    private func row(for entry: LogManager.LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(LogExport.onScreenTimestamp.string(from: entry.timestamp))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                // The level token is shown exactly as it is written into the
                // exported text, so it stays untranslated on purpose.
                Text(verbatim: entry.type.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color(for: entry.type))
            }

            Text(entry.message)
                .font(.caption.monospaced())
                .foregroundStyle(messageColor(for: entry.type))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
    }

    /// System reds and oranges rather than fixed hexes, so both stay legible
    /// against the light and dark list backgrounds.
    private func color(for type: LogManager.LogEntry.LogType) -> Color {
        switch type {
        case .error: return .red
        case .warning: return .orange
        case .info, .debug: return .secondary
        }
    }

    /// Errors and warnings carry their level colour into the message so they
    /// stand out at a glance; info reads as ordinary body text and debug stays
    /// muted, which is roughly how much attention each deserves.
    private func messageColor(for type: LogManager.LogEntry.LogType) -> Color {
        switch type {
        case .error: return .red
        case .warning: return .orange
        case .info: return .primary
        case .debug: return .secondary
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionMenu: some View {
        Menu {
            Button {
                copyAll()
            } label: {
                Label("Copy All", systemImage: "doc.on.doc")
            }

            ShareLink(
                item: LogArchive(header: LogExport.contextHeader(), entries: logManager.logs),
                preview: SharePreview("TLocation Logs")
            ) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }

            Divider()

            Button(role: .destructive) {
                showClearConfirmation = true
            } label: {
                Label("Clear Logs", systemImage: "trash")
            }
        } label: {
            Label("Log Actions", systemImage: "ellipsis.circle")
        }
        .disabled(logManager.logs.isEmpty)
    }

    /// Copies the *whole* log, never just what the filter is showing. This is
    /// the main way a log leaves the device, and an error line without the
    /// hundred info lines that led up to it is exactly the half-a-story that
    /// made these failures hard to diagnose in the first place.
    private func copyAll() {
        UIPasteboard.general.string = LogExport.document(
            header: LogExport.contextHeader(),
            entries: logManager.logs
        )
        Haptics.light()
        showCopyConfirmation(String(localized: "Log copied to the clipboard"))
    }

    /// Same self-cancelling dismissal as `SettingsView`'s status lines: only
    /// clears the toast if it still shows the message this call put there.
    private func showCopyConfirmation(_ message: String) {
        copyConfirmation = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                if copyConfirmation == message { copyConfirmation = nil }
            }
        }
    }
}
