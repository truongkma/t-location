//
//  DebugWidget.swift
//  DebugWidget
//
//  Created by Stephen on 5/30/25.
//

import WidgetKit
import SwiftUI
import UIKit

// MARK: - Favorites Widget ----------------------------------------------------

struct FavoritesEntry: TimelineEntry {
    let date: Date
    let bundleIDs: [String]
}

struct FavoritesProvider: TimelineProvider {
    private let sharedDefaults = UserDefaults(suiteName: "group.com.stik.sj")

    func placeholder(in context: Context) -> FavoritesEntry {
        FavoritesEntry(date: .now, bundleIDs: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (FavoritesEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FavoritesEntry>) -> Void) {
        let entry = makeEntry()
        completion(Timeline(entries: [entry], policy: .never))
    }

    private func makeEntry() -> FavoritesEntry {
        let favorites = sharedDefaults?.stringArray(forKey: "favoriteApps") ?? []
        return FavoritesEntry(date: .now, bundleIDs: Array(favorites.prefix(4)))
    }
}

struct FavoritesWidgetEntryView: View {
    let entry: FavoritesEntry

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { idx in
                if idx < entry.bundleIDs.count {
                    iconCell(bundleID: entry.bundleIDs[idx])
                } else {
                    placeholderCell()
                }
            }
        }
        .padding(8)
        .containerBackground(Color(UIColor.systemBackground), for: .widget)
    }

    @ViewBuilder
    private func iconCell(bundleID: String) -> some View {
        if let img = loadIcon(for: bundleID) {
            Link(destination: URL(string: "stikjit://enable-jit?bundle-id=\(bundleID)")!) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .cornerRadius(12)
            }
        } else {
            placeholderCell()
        }
    }

    @ViewBuilder
    private func placeholderCell() -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.systemGray5))
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.gray)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct FavoritesWidget: Widget {
    let kind: String = "FavoritesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FavoritesProvider()) { entry in
            FavoritesWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("StikDebug Favorites")
        .description("Quick-launch your top 4 favorite debug targets.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - System Apps Widget -------------------------------------------------

struct SystemAppSnapshot: Identifiable {
    let bundleID: String
    let displayName: String
    var id: String { bundleID }
}

struct SystemAppsEntry: TimelineEntry {
    let date: Date
    let items: [SystemAppSnapshot]
}

struct SystemAppsProvider: TimelineProvider {
    private let sharedDefaults = UserDefaults(suiteName: "group.com.stik.sj")

    func placeholder(in context: Context) -> SystemAppsEntry {
        SystemAppsEntry(date: .now, items: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (SystemAppsEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SystemAppsEntry>) -> Void) {
        let entry = makeEntry()
        completion(Timeline(entries: [entry], policy: .never))
    }

    private func makeEntry() -> SystemAppsEntry {
        let pinned = sharedDefaults?.stringArray(forKey: "pinnedSystemApps") ?? []
        let names = sharedDefaults?.dictionary(forKey: "pinnedSystemAppNames") as? [String: String] ?? [:]
        let snapshots = pinned.prefix(4).map { bundleID -> SystemAppSnapshot in
            let displayName = names[bundleID] ?? friendlyName(bundleID: bundleID)
            return SystemAppSnapshot(bundleID: bundleID, displayName: displayName)
        }
        return SystemAppsEntry(date: .now, items: snapshots)
    }

    private func friendlyName(bundleID: String) -> String {
        let components = bundleID.split(separator: ".")
        if let last = components.last {
            let cleaned = last.replacingOccurrences(of: "_", with: " ")
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed.capitalized }
        }
        return bundleID
    }
}

struct SystemAppsWidgetEntryView: View {
    let entry: SystemAppsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(entry.items) { item in
                Link(destination: URL(string: "stikjit://enable-jit?bundle-id=\(item.bundleID)")!) {
                    HStack(spacing: 10) {
                        icon(for: item.bundleID)
                            .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayName)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(item.bundleID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(UIColor.secondarySystemBackground).opacity(0.35))
                    )
                }
            }

            if entry.items.isEmpty {
                Text("Pin system apps from StikDebug to see them here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(12)
        .containerBackground(Color(UIColor.systemBackground), for: .widget)
    }

    @ViewBuilder
    private func icon(for bundleID: String) -> some View {
        if let image = loadIcon(for: bundleID) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(1, contentMode: .fill)
                .cornerRadius(10)
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(UIColor.systemGray5))
                .overlay(
                    Image(systemName: "app")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(.gray)
                )
        }
    }
}

struct SystemAppsWidget: Widget {
    let kind: String = "SystemAppsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SystemAppsProvider()) { entry in
            SystemAppsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Hidden System Apps")
        .description("Launch your pinned hidden system apps directly from the widget.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Shared Helpers -----------------------------------------------------

private func loadIcon(for bundleID: String) -> UIImage? {
    guard let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.stik.sj")
    else { return nil }
    let url = container
        .appendingPathComponent("icons", isDirectory: true)
        .appendingPathComponent("\(bundleID).png")
    return UIImage(contentsOfFile: url.path)
}
