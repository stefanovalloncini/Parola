import Foundation

/// How a stored title was set. Absent on a generated stamp ("Recording …", a working file's name,
/// or an older bundle written before this field existed) — a reader that sees no value treats the
/// stored title as generated, not typed.
public enum TitleSource: String, Codable, Sendable, CaseIterable {
    /// Typed by the user, through Rename.
    case user
    /// Read from the source itself (a link's own metadata), not generated on device.
    case source
}
