import Foundation
import os

/// A suite name no other test uses. Its plist is removed once the test process exits.
func temporarySuiteName(_ prefix: String = "test-") -> String {
    let name = prefix + UUID().uuidString
    TemporarySuites.register(name)
    return name
}

/// A throwaway `UserDefaults` suite, discarded once the test process exits. See `temporarySuiteName`.
func temporaryDefaults(_ prefix: String = "test-") -> UserDefaults {
    UserDefaults(suiteName: temporarySuiteName(prefix))!
}

enum TemporarySuites {
    private static let registered = OSAllocatedUnfairLock<[String]>(initialState: [])
    private static let sweepAtExit: Void = { _ = atexit { TemporarySuites.discardAll() } }()

    static func register(_ name: String) {
        _ = sweepAtExit
        registered.withLock { $0.append(name) }
    }

    /// Deletes `paths` from a process that outlives this one, retrying until they stay gone: cfprefsd
    /// writes every suite it knows about back to disk as this process goes away, so a plist removed
    /// from here reappears. On success the list file is deleted; a list file left in `listDirectory`
    /// means the sweeper gave up with files still on disk.
    @discardableResult
    static func sweep(
        plists paths: [String],
        listDirectory: URL = FileManager.default.temporaryDirectory,
        interval: Double = 2,
        passes: Int = 30
    ) -> URL? {
        guard !paths.isEmpty else { return nil }
        let list = listDirectory.appending(path: "parola-temporary-suites-\(UUID().uuidString)")
        do {
            try (paths.joined(separator: "\n") + "\n").write(to: list, atomically: true, encoding: .utf8)
        } catch {
            report("could not write the sweeper's list: \(error)")
            return nil
        }

        let script = """
        i=0
        while [ "$i" -lt \(passes) ]; do
          i=$((i + 1))
          sleep \(interval)
          found=0
          while IFS= read -r plist; do
            if [ -e "$plist" ]; then
              rm -f "$plist"
              found=1
            fi
          done < "$0"
          if [ "$found" -eq 0 ]; then
            rm -f "$0"
            exit 0
          fi
        done
        exit 1
        """
        let sweeper = Process()
        sweeper.executableURL = URL(filePath: "/bin/sh")
        sweeper.arguments = ["-c", script, list.path]
        sweeper.standardOutput = FileHandle.nullDevice
        sweeper.standardError = FileHandle.nullDevice
        do {
            try sweeper.run()
        } catch {
            report("could not start the sweeper: \(error)")
            return nil
        }
        return list
    }

    private static func discardAll() {
        let suiteNames = registered.withLock { $0 }
        guard let preferences = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appending(path: "Preferences")
        else { return }
        sweep(plists: suiteNames.map { preferences.appending(path: "\($0).plist").path })
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("temporary defaults: \(message)\n".utf8))
    }
}
