import Foundation
import Darwin

/// Availability at an explicit file selection is independent of discovery's
/// cached URL metadata. Call from the file-loading queue, never the UI thread.
nonisolated enum LibraryFileAdmission {
    enum Failure: Error {
        case notLocalFile
        case invalidPath
        case notRegularFile
    }

    static func requireReadableRegularFile(at url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            throw Failure.notLocalFile
        }
        let descriptor = try url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { throw Failure.invalidPath }
            // Nonblocking keeps a replaced FIFO/device from stalling selection;
            // no-follow preserves discovery's exclusion of symbolic-link files.
            let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return descriptor
        }
        defer { _ = Darwin.close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw Failure.notRegularFile
        }
    }
}
