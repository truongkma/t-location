//
//  DebugWidgetBundle.swift
//  DebugWidget
//
//  Created by Stephen on 5/30/25.
//

import WidgetKit
import SwiftUI

@main
struct AppsWidget: Widget {
    let kind: String = "AppsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AppsProvider()) { entry in
            AppsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("StikDebug Favorites")
        .description("Quick-launch your top 4 favorite debug targets.")
        .supportedFamilies([.systemMedium])
    }
}
