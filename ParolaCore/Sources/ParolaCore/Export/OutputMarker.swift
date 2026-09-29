import Foundation

/// The extended attribute Parola puts on every file it writes: sidecars, auto-exports, burned videos and
/// the exports a user saves. A watched folder skips a marked file as an arrival. The value names the
/// owner a sidecar was written for, so a later run for that owner may replace it and nothing else.
public enum OutputMarker {
    /// `#S` asks sync services such as iCloud Drive to carry the attribute along with the file.
    public static let attributeName = "app.parola.output#S"

    /// An empty owner marks a file no later run replaces, such as an export the user saved.
    public static func mark(_ url: URL, owner: String = "") {
        let value = Array(owner.utf8)
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return setxattr(path, attributeName, value, value.count, 0, 0)
        }
        if status != 0 {
            ParolaLog.error(.export, "could not mark a file Parola wrote", [.error: .error(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))])
        }
    }

    /// Nil when Parola did not write the file, or it no longer exists.
    public static func owner(of url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let size = getxattr(path, attributeName, nil, 0, 0, 0)
            guard size >= 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            let read = getxattr(path, attributeName, &buffer, size, 0, 0)
            guard read >= 0 else { return nil }
            return String(decoding: buffer.prefix(read), as: UTF8.self)
        }
    }

    public static func isMarked(_ url: URL) -> Bool {
        owner(of: url) != nil
    }
}
