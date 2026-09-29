import Darwin
import Foundation

/// This instance's hold on a library: a lock file kept locked while the model lives, so other instances leave its checkpoints alone.
final class RecoveryOwner: Sendable {
    let id: String
    private let lockPath: String
    private let descriptor: Int32

    init?(directory: URL) {
        let id = UUID().uuidString
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("\(id).lock").path
        // Created and locked in one call, so no other instance ever sees the file unlocked.
        let descriptor = open(path, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return nil }
        self.id = id
        self.lockPath = path
        self.descriptor = descriptor
    }

    deinit {
        unlink(lockPath)
        close(descriptor)
    }

    /// Whether the instance that wrote a checkpoint is still running. Only a missing or unlocked file counts as gone.
    static func isAlive(_ owner: String, in directory: URL) -> Bool {
        let path = directory.appendingPathComponent("\(owner).lock").path
        let descriptor = open(path, O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return errno != ENOENT }
        close(descriptor)
        return false
    }

    /// Deletes the lock files of instances that are gone, each while holding its lock.
    static func removeDeadLocks(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "lock" {
            let descriptor = open(file.path, O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            unlink(file.path)
            close(descriptor)
        }
    }
}
