import Foundation
import Darwin

/// Shared descriptor and physical identity boundary for library file actions.
/// Callers open descendants relative to an already pinned directory, with no-follow flags.
nonisolated struct LibraryFileIdentity: Sendable, Equatable {
    let device: Int64
    let inode: UInt64
    let generation: UInt64

    init(_ attributes: stat) {
        device = Int64(attributes.st_dev)
        inode = UInt64(attributes.st_ino)
        generation = UInt64(attributes.st_gen)
    }
}


nonisolated final class LibraryFileHandle: @unchecked Sendable {
    let descriptor: Int32

    init(path: String, flags: Int32) throws {
        descriptor = Darwin.open(path, flags)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    init(parent: LibraryFileHandle, name: String, flags: Int32) throws {
        descriptor = Darwin.openat(parent.descriptor, name, flags)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func attributes() throws -> stat {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return attributes
    }

    deinit { _ = Darwin.close(descriptor) }
}
