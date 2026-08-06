//
//  AppBootstrapper.swift
//  TLocation
//

import Foundation
import ObjectiveC.runtime
import UIKit

enum AppBootstrapper {
    static func configure() {
        UserDefaults.standard.register(defaults: [
            "keepAliveAudio": true,
            "keepAliveLocation": true
        ])

        if UserDefaults.standard.bool(forKey: "keepAliveAudio") {
            BackgroundAudioManager.shared.start()
        }

        applyDocumentPickerCopyWorkaround()
    }

    // Required so pairing-file imports copy correctly from the Files picker.
    private static func applyDocumentPickerCopyWorkaround() {
        let fixedSelector = NSSelectorFromString("fix_initForOpeningContentTypes:asCopy:")
        let originalSelector = #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:))

        guard let fixedMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, fixedSelector),
              let originalMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, originalSelector) else {
            return
        }

        method_exchangeImplementations(originalMethod, fixedMethod)
    }
}
