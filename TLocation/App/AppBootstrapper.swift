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
            "keepAliveLocation": true
        ])

        LanguageSettings.restoreAtLaunch()

        removeLegacyFFILogFile()
        applyDocumentPickerCopyWorkaround()
    }

    /// Deletes the `idevice_log.txt` that older builds had the Rust FFI logger
    /// write into Documents — a persistent, plain-text record of everything the
    /// device layer did, including device identifiers, which `UIFileSharingEnabled`
    /// published in the Files app. `JITEnableContext` no longer initialises a file
    /// logger at all, and nothing in the app has ever read this file, so upgrading
    /// users get it removed rather than keeping a stale copy forever.
    private static func removeLegacyFFILogFile() {
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        try? fileManager.removeItem(at: documents.appendingPathComponent("idevice_log.txt"))
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
