import Foundation

/// Where an entry's media came from, stamped when the bundle is written so a reader never has to
/// guess it from the name of a working file.
public enum EntrySource: String, Codable, Sendable, CaseIterable {
    case file
    case microphone
    case systemAudio
    case web
}
