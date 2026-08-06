//
//  UIDocumentPickerViewController+CopyWorkaround.swift
//  TLocation
//

import UIKit
import UniformTypeIdentifiers

extension UIDocumentPickerViewController {
    @objc func fix_init(
        forOpeningContentTypes contentTypes: [UTType],
        asCopy: Bool
    ) -> UIDocumentPickerViewController {
        fix_init(forOpeningContentTypes: contentTypes, asCopy: true)
    }
}
