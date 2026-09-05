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
