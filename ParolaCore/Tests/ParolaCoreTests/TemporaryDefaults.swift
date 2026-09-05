import Foundation
import os

/// A suite name no other test uses. Its plist is removed once the test process exits.
func temporarySuiteName(_ prefix: String = "parola-test-") -> String {
    let name = prefix + UUID().uuidString
    TemporarySuites.register(name)
    return name
}

/// A throwaway `UserDefaults` suite, discarded once the test process exits. See `temporarySuiteName`.
func temporaryDefaults(_ prefix: String = "parola-test-") -> UserDefaults {
    UserDefaults(suiteName: temporarySuiteName(prefix))!
}

private enum TemporarySuites {
    private static let names = OSAllocatedUnfairLock<[String]>(initialState: [])
    private static let sweepAtExit: Void = { _ = atexit { TemporarySuites.discardAll() } }()

    static func register(_ name: String) {
        _ = sweepAtExit
        names.withLock { $0.append(name) }
    }

    private static func discardAll() {
        let names = names.withLock { $0 }
        guard !names.isEmpty,
              let preferences = FileManager.default
                .urls(for: .libraryDirectory, in: .userDomainMask).first?
                .appending(path: "Preferences")
        else { return }
        let list = FileManager.default.temporaryDirectory
            .appending(path: "parola-temporary-suites-\(ProcessInfo.processInfo.processIdentifier)")
        let paths = names.map { preferences.appending(path: "\($0).plist").path }.joined(separator: "\n")
        guard (try? paths.write(to: list, atomically: true, encoding: .utf8)) != nil else { return }

        // cfprefsd writes every suite it knows about back to disk as this process goes away, so the
        // plists have to be removed by something that outlives it and keeps trying.
        let sweeper = Process()
        sweeper.executableURL = URL(filePath: "/bin/sh")
        sweeper.arguments = [
            "-c",
            #"for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 2; xargs rm -f < "$0"; done; rm -f "$0""#,
            list.path,
        ]
        sweeper.standardOutput = FileHandle.nullDevice
        sweeper.standardError = FileHandle.nullDevice
        try? sweeper.run()
    }
}
