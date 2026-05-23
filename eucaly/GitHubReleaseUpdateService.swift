import Foundation
import CryptoKit

actor GitHubReleaseUpdateService {
    private let session: URLSession
    private let latestReleaseURL: URL
    private let currentVersionProvider: @Sendable () -> String

    init(
        session: URLSession = .shared,
        latestReleaseURL: URL = URL(string: "https://api.github.com/repos/sukujgrg/eucaly/releases/latest")!,
        currentVersionProvider: @escaping @Sendable () -> String = GitHubReleaseUpdateService.bundleVersion
    ) {
        self.session = session
        self.latestReleaseURL = latestReleaseURL
        self.currentVersionProvider = currentVersionProvider
    }

    func checkForUpdate() async throws -> AppUpdateRelease? {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("eucaly", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            return nil
        }

        let release = try JSONDecoder().decode(GitHubReleaseResponseModel.self, from: data)
        guard
            let latestVersion = AppVersionModel(release.tagName),
            let currentVersion = AppVersionModel(currentVersionProvider()),
            latestVersion > currentVersion
        else {
            return nil
        }

        return AppUpdateRelease(
            version: latestVersion.displayValue,
            releaseURL: release.htmlURL,
            asset: release.primaryDownloadAsset,
            checksumAsset: release.primaryChecksumAsset
        )
    }

    func downloadUpdate(_ release: AppUpdateRelease) async throws -> AppDownloadedUpdate {
        guard let asset = release.asset else {
            throw AppUpdateError.missingReleaseAsset
        }

        let (temporaryURL, response) = try await session.download(from: asset.downloadURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw AppUpdateError.downloadFailed
        }

        let destinationDirectory = try updatesDirectory()
        let destinationURL = destinationDirectory.appendingPathComponent(asset.name)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)

        guard let checksumAsset = release.checksumAsset else {
            throw AppUpdateError.missingChecksumAsset
        }

        try await verifyChecksum(for: destinationURL, checksumAsset: checksumAsset)
        return AppDownloadedUpdate(archiveURL: destinationURL)
    }

    private static func bundleVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private func updatesDirectory() throws -> URL {
        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = applicationSupportURL
            .appendingPathComponent("eucaly", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }

    private func verifyChecksum(for fileURL: URL, checksumAsset: GitHubReleaseAssetModel) async throws {
        let (data, response) = try await session.data(from: checksumAsset.downloadURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw AppUpdateError.checksumDownloadFailed
        }

        let checksumText = String(decoding: data, as: UTF8.self)
        guard let expectedChecksum = AppUpdateChecksumParser.expectedChecksum(from: checksumText)
        else {
            throw AppUpdateError.invalidChecksum
        }

        let fileData = try Data(contentsOf: fileURL)
        let actualChecksum = SHA256.hash(data: fileData)
            .map { String(format: "%02x", $0) }
            .joined()

        guard actualChecksum == expectedChecksum else {
            throw AppUpdateError.checksumMismatch
        }
    }
}

nonisolated struct AppUpdateRelease: Equatable {
    let version: String
    let releaseURL: URL
    let asset: GitHubReleaseAssetModel?
    let checksumAsset: GitHubReleaseAssetModel?
}

nonisolated struct AppDownloadedUpdate: Equatable {
    let archiveURL: URL
}

nonisolated struct GitHubReleaseResponseModel: Decodable {
    let tagName: String
    let htmlURL: URL
    let assets: [GitHubReleaseAssetModel]

    var primaryDownloadAsset: GitHubReleaseAssetModel? {
        assets.first { asset in
            asset.name.hasSuffix(".dmg")
        } ?? assets.first { asset in
            asset.name.hasSuffix(".zip") && !asset.name.hasSuffix(".sha256")
        }
    }

    var primaryChecksumAsset: GitHubReleaseAssetModel? {
        guard let primaryDownloadAsset else {
            return nil
        }

        return assets.first { asset in
            asset.name == "\(primaryDownloadAsset.name).sha256"
        } ?? assets.first { asset in
            asset.name.hasSuffix(".sha256")
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

nonisolated struct GitHubReleaseAssetModel: Decodable, Equatable {
    let name: String
    let downloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
    }
}

nonisolated enum AppUpdateError: Error {
    case missingReleaseAsset
    case downloadFailed
    case missingChecksumAsset
    case checksumDownloadFailed
    case invalidChecksum
    case checksumMismatch
}

nonisolated struct AppUpdateChecksumParser {
    static func expectedChecksum(from checksumText: String) -> String? {
        checksumText
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .first
            .map(String.init)?
            .lowercased()
    }
}

nonisolated struct AppVersionModel: Comparable, Equatable {
    let displayValue: String
    private let components: [Int]

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        let withoutBuildMetadata = withoutPrefix
            .split(separator: "+", maxSplits: 1)
            .first
            .map(String.init) ?? withoutPrefix
        let versionText = withoutBuildMetadata
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init) ?? withoutBuildMetadata
        let rawComponents = versionText
            .split(separator: ".")
        let parsedComponents = rawComponents.compactMap { Int($0) }

        guard !parsedComponents.isEmpty,
              parsedComponents.count == rawComponents.count
        else {
            return nil
        }

        displayValue = withoutPrefix
        components = parsedComponents
    }

    static func < (lhs: AppVersionModel, rhs: AppVersionModel) -> Bool {
        let maxCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<maxCount {
            let leftValue = index < lhs.components.count ? lhs.components[index] : 0
            let rightValue = index < rhs.components.count ? rhs.components[index] : 0
            if leftValue != rightValue {
                return leftValue < rightValue
            }
        }
        return false
    }

    static func == (lhs: AppVersionModel, rhs: AppVersionModel) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
