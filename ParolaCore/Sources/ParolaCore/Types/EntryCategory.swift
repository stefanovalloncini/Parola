import Foundation

public enum EntryCategory: String, Codable, Sendable, CaseIterable {
    case transcription
    case meeting
    case dictation
}
