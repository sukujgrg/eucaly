import Foundation

/// Installed NDI runtime locations; querying these paths never loads the SDK.
nonisolated enum NDIRuntimeInstallation {
    static let searchPaths = [
        "/usr/local/lib/libndi.dylib",
        "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib"
    ]
}
