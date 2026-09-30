import Darwin
import Foundation

/// The unit-test host's own defaults suite and library, named after its process.
struct TestHostSandbox: Sendable {
    static let namePrefix = "parola-test-host-"

    let defaultsSuite: String
    let library: URL

    /// Prepared once per process: preparing again would clear the suite the running host reads.
    static let current = prepare(
        pid: getpid(),
        preferences: URL.libraryDirectory.appending(path: "Preferences", directoryHint: .isDirectory),
        temporary: FileManager.default.temporaryDirectory
    )

    /// `xcodebuild test` sets it before `ParolaApp.init` runs; under Swift Testing its value is empty.
    static func isTestHost(_ environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    static func prepare(pid: Int32, preferences: URL, temporary: URL) -> TestHostSandbox {
        sweepLeftovers(preferences: preferences, temporary: temporary)
        let name = namePrefix + String(pid)
        UserDefaults.standard.removePersistentDomain(forName: name)
        let root = temporary.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        let library = root.appending(path: "Library", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        return TestHostSandbox(defaultsSuite: name, library: library)
    }

    /// Two hosts can run at once, so only what a finished host left behind goes.
    static func sweepLeftovers(preferences: URL, temporary: URL) {
        for (folder, suffix) in [(preferences, ".plist"), (temporary, "")] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names {
                guard let pid = leftoverPID(name, suffix: suffix), !isRunning(pid) else { continue }
                try? FileManager.default.removeItem(at: folder.appending(path: name))
            }
        }
    }

    static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func leftoverPID(_ name: String, suffix: String) -> Int32? {
        guard name.hasPrefix(namePrefix), name.hasSuffix(suffix) else { return nil }
        return Int32(name.dropFirst(namePrefix.count).dropLast(suffix.count))
    }
}
