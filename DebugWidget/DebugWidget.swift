//
//  DebugWidget.swift
//  DebugWidget
//
//  Created by Stephen on 5/30/25.
//

import WidgetKit
import SwiftUI
import UIKit

// MARK: - Timeline Entry
struct AppsEntry: TimelineEntry {
    let date: Date
    let bundleIDs: [String]
}

// MARK: - Provider
struct AppsProvider: TimelineProvider {
    private let sharedDefaults = UserDefaults(suiteName: "group.com.stik.sj")

    func placeholder(in context: Context) -> AppsEntry {
        AppsEntry(date: .now, bundleIDs: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (AppsEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AppsEntry>) -> Void) {
        let entry = makeEntry()
        completion(Timeline(entries: [entry], policy: .never))
    }

    private func makeEntry() -> AppsEntry {
        let favs = sharedDefaults?.stringArray(forKey: "favoriteApps") ?? []
        let bundleIDs = Array(favs.prefix(4))
        return AppsEntry(date: .now, bundleIDs: bundleIDs)
    }
}

// MARK: - Widget View
struct AppsWidgetEntryView: View {
    let entry: AppsEntry

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { idx in
                if idx < entry.bundleIDs.count {
                    IconCell(bundleID: entry.bundleIDs[idx])
                } else {
                    PlaceholderCell()
                }
            }
        }
        .padding(8)
        .containerBackground(Color(UIColor.systemBackground), for: .widget)
    }

    @ViewBuilder
    private func IconCell(bundleID: String) -> some View {
        if let img = loadIcon(for: bundleID) {
            Link(destination: URL(string: "stikjit://enable-jit?bundle-id=\(bundleID)")!) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .cornerRadius(12)
            }
        } else {
            PlaceholderCell()
        }
    }

    @ViewBuilder
    private func PlaceholderCell() -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.systemGray5))
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.gray)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func loadIcon(for bundleID: String) -> UIImage? {
        guard let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.com.stik.sj")
        else { return nil }
        let url = container
            .appendingPathComponent("icons", isDirectory: true)
            .appendingPathComponent("\(bundleID).png")
        return UIImage(contentsOfFile: url.path)
    }
}
