//
//  DeveloperDiskImageService.swift
//  TLocation
//

import Foundation

final class DeveloperDiskImageService {
    static let shared = DeveloperDiskImageService()

    private let fileManager: FileManager
    private let session: URLSession

    init(fileManager: FileManager = .default, session: URLSession = .shared) {
        self.fileManager = fileManager
        self.session = session
    }

    func downloadMissingFiles() async throws {
        for item in Self.downloadItems {
            let destinationURL = URL.documentsDirectory.appendingPathComponent(item.relativePath)
            guard !fileManager.fileExists(atPath: destinationURL.path) else {
                continue
            }
            try await downloadFile(from: item.urlString, to: destinationURL)
        }
    }

    func downloadFile(from urlString: String, to destinationURL: URL) async throws {
        let fileName = destinationURL.lastPathComponent

        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "https" else {
            LogManager.shared.addErrorLog("DDI download of \(fileName) rejected an unusable URL: \(urlString)")
            throw DDIDownloadError.invalidURL(urlString)
        }

        LogManager.shared.addInfoLog("DDI download started: \(fileName) from \(urlString)")

        let (temporaryURL, response) = try await session.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            LogManager.shared.addErrorLog("DDI download of \(fileName) got a non-HTTP response")
            throw DDIDownloadError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            LogManager.shared.addErrorLog("DDI download of \(fileName) got HTTP \(httpResponse.statusCode)")
            throw DDIDownloadError.badStatus(httpResponse.statusCode)
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)

        let attributes = try? fileManager.attributesOfItem(atPath: destinationURL.path)
        let size = (attributes?[.size] as? Int).map(String.init) ?? "unknown"
        LogManager.shared.addInfoLog("DDI download finished: \(fileName) (\(size) bytes)")
    }

    func redownload(progressHandler: ((Double, String) -> Void)? = nil) async throws {
        let totalStages = Double(Self.downloadItems.count + 1)
        var completedStages = 0.0

        LogManager.shared.addInfoLog("DDI redownload requested; removing the existing files")
        progressHandler?(0.0, String(localized: "Removing existing DDI files…"))
        for item in Self.downloadItems {
            let fileURL = URL.documentsDirectory.appendingPathComponent(item.relativePath)
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        }

        completedStages += 1.0
        progressHandler?(completedStages / totalStages, String(localized: "Starting downloads…"))

        for item in Self.downloadItems {
            // `item.name` stays English: these are the literal artefact names
            // inside Apple's DDI package, not prose.
            let name = item.name
            progressHandler?(completedStages / totalStages, String(localized: "Downloading \(name)…"))
            let destinationURL = URL.documentsDirectory.appendingPathComponent(item.relativePath)
            try await downloadFile(from: item.urlString, to: destinationURL)
            completedStages += 1.0
            progressHandler?(completedStages / totalStages, String(localized: "\(name) ready"))
        }

        LogManager.shared.addInfoLog("DDI redownload complete")
        progressHandler?(1.0, String(localized: "DDI download complete."))
    }

    private static let downloadItems: [DDIDownloadItem] = [
        .init(
            name: "Build Manifest",
            relativePath: "DDI/BuildManifest.plist",
            urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/BuildManifest.plist"
        ),
        .init(
            name: "Image",
            relativePath: "DDI/Image.dmg",
            urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg"
        ),
        .init(
            name: "TrustCache",
            relativePath: "DDI/Image.dmg.trustcache",
            urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg.trustcache"
        )
    ]
}

private struct DDIDownloadItem {
    let name: String
    let relativePath: String
    let urlString: String
}

enum DDIDownloadError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let string):
            return String(localized: "Invalid download URL: \(string)")
        case .invalidResponse:
            return String(localized: "The DDI server returned an invalid response.")
        case .badStatus(let statusCode):
            return String(localized: "The DDI server returned HTTP \(statusCode).")
        }
    }
}

func redownloadDDI(progressHandler: ((Double, String) -> Void)? = nil) async throws {
    try await DeveloperDiskImageService.shared.redownload(progressHandler: progressHandler)
}
