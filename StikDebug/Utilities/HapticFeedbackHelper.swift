//
//  HapticFeedbackHelper.swift
//  StikDebug
//
//  Created by Stephen on 3/27/25.
//

import SwiftUI

struct HapticFeedbackHelper {
    static func trigger() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }
}
