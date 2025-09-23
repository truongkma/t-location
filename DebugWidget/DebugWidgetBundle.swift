//
//  DebugWidgetBundle.swift
//  DebugWidget
//
//  Created by Stephen on 5/30/25.
//

import WidgetKit
import SwiftUI

@main
struct StikDebugWidgetBundle: WidgetBundle {
    var body: some Widget {
        FavoritesWidget()
        // SystemAppsWidget() // Temporarily disabled
    }
}
