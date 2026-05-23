import Foundation
import Darwin

struct UpdaterArguments {
    let archiveURL: URL
    let targetURL: URL
    let bundleIdentifier: String
    let parentProcessID: pid_t
}

enum UpdaterError: Error {
    case missingArgument(String)
    case invalidParentProcessID
    case appNotFoundInArchive
    case bundleIdentifierMismatch(expected: String, actual: String?)
    case commandFailed(String, Int32)
}

var fallbackLaunchURL: URL?
var extractionURLForCleanup: URL?

do {
    let arguments = try parseArguments()
    fallbackLaunchURL = arguments.targetURL
    waitForParentToExit(arguments.parentProcessID)
    let extractedAppURL = try extractApp(from: arguments.archiveURL)
    let extractionURL = extractedAppURL.deletingLastPathComponent()
    extractionURLForCleanup = extractionURL
    try validateApp(at: extractedAppURL, bundleIdentifier: arguments.bundleIdentifier)
    try replaceApp(at: arguments.targetURL, with: extractedAppURL)
    try? FileManager.default.removeItem(at: arguments.archiveURL)
    try? FileManager.default.removeItem(at: extractionURL)
    extractionURLForCleanup = nil
    try launchApp(at: arguments.targetURL)
} catch {
    if let extractionURLForCleanup {
        try? FileManager.default.removeItem(at: extractionURLForCleanup)
    }
    if let fallbackLaunchURL {
        try? launchApp(at: fallbackLaunchURL)
    }
    FileHandle.standardError.write(Data("Update failed: \(error)\n".utf8))
    exit(1)
}

private func parseArguments() throws -> UpdaterArguments {
    let rawArguments = Array(CommandLine.arguments.dropFirst())

    func value(after key: String) throws -> String {
        guard let keyIndex = rawArguments.firstIndex(of: key),
              rawArguments.indices.contains(keyIndex + 1)
        else {
            throw UpdaterError.missingArgument(key)
        }
        return rawArguments[keyIndex + 1]
    }

    guard let parentProcessID = pid_t(try value(after: "--parent-pid")) else {
        throw UpdaterError.invalidParentProcessID
    }

    return UpdaterArguments(
        archiveURL: URL(fileURLWithPath: try value(after: "--archive")),
        targetURL: URL(fileURLWithPath: try value(after: "--target")),
        bundleIdentifier: try value(after: "--bundle-id"),
        parentProcessID: parentProcessID
    )
}

private func waitForParentToExit(_ processID: pid_t) {
    while kill(processID, 0) == 0 {
        usleep(200_000)
    }
}

private func extractApp(from archiveURL: URL) throws -> URL {
    let extractionURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("eucaly-update-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: extractionURL,
        withIntermediateDirectories: true
    )

    try runCommand(
        executablePath: "/usr/bin/ditto",
        arguments: [
            "-x",
            "-k",
            archiveURL.path,
            extractionURL.path
        ]
    )

    let contents = try FileManager.default.contentsOfDirectory(
        at: extractionURL,
        includingPropertiesForKeys: nil
    )
    guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
        throw UpdaterError.appNotFoundInArchive
    }

    return appURL
}

private func validateApp(at appURL: URL, bundleIdentifier: String) throws {
    let infoURL = appURL
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("Info.plist")
    let infoData = try Data(contentsOf: infoURL)
    let plist = try PropertyListSerialization.propertyList(
        from: infoData,
        options: [],
        format: nil
    )
    let actualBundleIdentifier = (plist as? [String: Any])?["CFBundleIdentifier"] as? String

    guard actualBundleIdentifier == bundleIdentifier else {
        throw UpdaterError.bundleIdentifierMismatch(
            expected: bundleIdentifier,
            actual: actualBundleIdentifier
        )
    }
}

private func replaceApp(at targetURL: URL, with newAppURL: URL) throws {
    let backupURL = targetURL
        .deletingLastPathComponent()
        .appendingPathComponent(".\(targetURL.lastPathComponent).backup-\(UUID().uuidString)")

    try FileManager.default.moveItem(at: targetURL, to: backupURL)

    do {
        try FileManager.default.moveItem(at: newAppURL, to: targetURL)
        try? FileManager.default.removeItem(at: backupURL)
        removeStaleBackups(for: targetURL)
    } catch {
        try? FileManager.default.moveItem(at: backupURL, to: targetURL)
        throw error
    }
}

private func removeStaleBackups(for targetURL: URL) {
    let parentURL = targetURL.deletingLastPathComponent()
    let backupPrefix = ".\(targetURL.lastPathComponent).backup-"
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: parentURL,
        includingPropertiesForKeys: nil
    ) else {
        return
    }

    for url in contents where url.lastPathComponent.hasPrefix(backupPrefix) {
        try? FileManager.default.removeItem(at: url)
    }
}

private func launchApp(at targetURL: URL) throws {
    try runCommand(
        executablePath: "/usr/bin/open",
        arguments: [targetURL.path]
    )
}

private func runCommand(executablePath: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw UpdaterError.commandFailed(executablePath, process.terminationStatus)
    }
}
