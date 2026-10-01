import Foundation
import os

/// Where live recorders keep their in-flight files. Defaults to the temp directory;
/// the app points it at a library-adjacent folder so a take survives a failed
/// transcription, a crash, and the OS temp purge.
public enum RecordingScratch {
    private static let override = OSAllocatedUnfairLock<URL?>(initialState: nil)

    public static var directory: URL {
        override.withLock { $0 } ?? FileManager.default.temporaryDirectory
    }

    public static func setDirectory(_ url: URL?) {
        override.withLock { $0 = url }
    }

    /// The prefixes of recorded takes; anything else left in the folder is dictation or preview scratch.
    public static let takePrefixes = ["parola-mic", "parola-system", "parola-recording"]
    public static let dictationPrefix = "parola-dictation"
    public static let previewPrefix = "parola-preview"
    /// A meeting's microphone track: it belongs to its take, so it is never a take of its own.
    public static let meetingMicPrefix = "parola-meetmic"
    /// A meeting's two tracks while they are mixed into one; a leftover is scratch.
    public static let meetingMixPrefix = "parola-meetmix"

    /// Whether a leftover file is a recorded take, which a sweep brings back, rather than scratch it may delete.
    public static func isTake(_ file: URL) -> Bool {
        let name = file.lastPathComponent
        return file.pathExtension.lowercased() == "wav" && takePrefixes.contains { name.hasPrefix($0 + "-") }
    }

    public static func isMeetingMic(_ file: URL) -> Bool {
        file.pathExtension.lowercased() == "wav" && file.lastPathComponent.hasPrefix(meetingMicPrefix + "-")
    }

    /// The microphone track for a meeting recording into `take`, named after it so a sweep can pair the two;
    /// a take with no take name of its own, like a test fixture, gets a fresh one.
    public static func meetingMicURL(for take: URL?) -> URL {
        guard let take, isTake(take), let prefix = takePrefixes.first(where: { take.lastPathComponent.hasPrefix($0 + "-") }) else {
            return fileURL(prefix: meetingMicPrefix)
        }
        let rest = take.lastPathComponent.dropFirst(prefix.count + 1)
        return take.deletingLastPathComponent().appendingPathComponent("\(meetingMicPrefix)-\(rest)")
    }

    /// The take names a meeting's microphone track can belong to, in the same folder.
    public static func takeNames(pairedWith meetingMic: URL) -> [String] {
        guard isMeetingMic(meetingMic) else { return [] }
        let rest = meetingMic.lastPathComponent.dropFirst(meetingMicPrefix.count + 1)
        return takePrefixes.map { "\($0)-\(rest)" }
    }

    /// A unique URL for a new take, creating the directory if needed.
    public static func fileURL(prefix: String) -> URL {
        let dir = directory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            ParolaLog.error(
                .audioRecording,
                "could not create the recording scratch directory",
                [.error: .error(error)]
            )
        }
        return dir.appendingPathComponent("\(prefix)-\(UUID().uuidString).wav")
    }
}
