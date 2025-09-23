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

struct FavoriteSnapshot: Identifiable {
    let bundleID: String
    let displayName: String
    var id: String { bundleID }
}

struct FavoritesEntry: TimelineEntry {
    let date: Date
    let items: [FavoriteSnapshot]
}

struct FavoritesProvider: TimelineProvider {
    private let sharedDefaults = UserDefaults(suiteName: "group.com.stik.sj")

    func placeholder(in context: Context) -> FavoritesEntry {
        FavoritesEntry(date: .now, items: [])
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
        let names = sharedDefaults?.dictionary(forKey: "favoriteAppNames") as? [String: String] ?? [:]
        let items = favorites.prefix(4).map { bundleID -> FavoriteSnapshot in
            let display = names[bundleID] ?? friendlyNameFromBundleID(bundleID)
            return FavoriteSnapshot(bundleID: bundleID, displayName: display)
        }
        return FavoritesEntry(date: .now, items: items)
    }
}

struct FavoritesWidgetEntryView: View {
    let entry: FavoritesEntry

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { idx in
                if idx < entry.items.count {
                    labeledIconCell(item: entry.items[idx])
                } else {
                    placeholderCell()
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(8)
        .containerBackground(Color(UIColor.systemBackground), for: .widget)
    }

    @ViewBuilder
    private func labeledIconCell(item: FavoriteSnapshot) -> some View {
        if let img = loadIcon(for: item.bundleID) {
            Link(destination: URL(string: "stikjit://enable-jit?bundle-id=\(item.bundleID)")!) {
                VStack(spacing: 6) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .cornerRadius(12)
                    Text(item.displayName)
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            placeholderCell()
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func placeholderCell() -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(UIColor.systemGray5))
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.gray)
            }
            .aspectRatio(1, contentMode: .fit)
            Text(" ")
                .font(.caption2)
                .opacity(0) // keep height consistent
        }
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

// MARK: - Launch Shortcuts Widget (formerly System Apps) ---------------------

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
        // This list now represents "pinned launch apps" (system or other)
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
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { idx in
                if idx < entry.items.count {
                    labeledIconCell(item: entry.items[idx])
                } else {
                    placeholderCell()
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(8)
        .containerBackground(Color(UIColor.systemBackground), for: .widget)
    }

    @ViewBuilder
    private func labeledIconCell(item: SystemAppSnapshot) -> some View {
        if let img = loadIcon(for: item.bundleID) {
            // Use launch-app to mirror non-debug launch behavior
            Link(destination: URL(string: "stikjit://launch-app?bundle-id=\(item.bundleID)")!) {
                VStack(spacing: 6) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .cornerRadius(12)
                    Text(item.displayName)
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            placeholderCell()
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func placeholderCell() -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(UIColor.systemGray5))
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.gray)
            }
            .aspectRatio(1, contentMode: .fit)
            Text(" ")
                .font(.caption2)
                .opacity(0) // keep height consistent
        }
    }
}

struct SystemAppsWidget: Widget {
    let kind: String = "SystemAppsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SystemAppsProvider()) { entry in
            SystemAppsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Launch Shortcuts")
        .description("Pin any app to launch directly from the widget.")
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

/// Fallback readable name from a bundle identifier
private func friendlyNameFromBundleID(_ bundleID: String) -> String {
    let components = bundleID.split(separator: ".")
    if let last = components.last {
        let cleaned = last.replacingOccurrences(of: "_", with: " ")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed.capitalized }
    }
    return bundleID
}

