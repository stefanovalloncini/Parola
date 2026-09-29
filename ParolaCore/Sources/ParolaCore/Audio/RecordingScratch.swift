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

    /// Whether a leftover file is a recorded take, which a sweep brings back, rather than scratch it may delete.
    public static func isTake(_ file: URL) -> Bool {
        let name = file.lastPathComponent
        return file.pathExtension.lowercased() == "wav" && takePrefixes.contains { name.hasPrefix($0 + "-") }
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
