import Foundation

/// Writes a file's bytes through to the disk, so a rename that puts it in another file's place never lands before its contents do.
public enum DiskFlush {
    public static func flush(_ file: URL) throws {
        let descriptor = open(file.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        // F_FULLFSYNC empties the drive's own cache too; a volume that can't do that still gets fsync.
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
