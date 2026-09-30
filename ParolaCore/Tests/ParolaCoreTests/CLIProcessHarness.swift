import Foundation
import Testing

/// The built `parola` binary. nil when it isn't in the products directory — e.g. under xcodebuild,
/// where the CLI product isn't built — so the process suites skip visibly instead of failing.
let parolaBinaryURL: URL? = {
    var candidates: [URL] = []
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("parola"))
    }
    if let main = Bundle.main.executableURL {
        var dir = main.deletingLastPathComponent()
        for _ in 0..<5 {
            candidates.append(dir.appendingPathComponent("parola"))
            dir.deleteLastPathComponent()
        }
    }
    let sourceFile = URL(fileURLWithPath: #filePath)
    let packageRoot = sourceFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    candidates.append(packageRoot.appendingPathComponent(".build/debug/parola"))
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}()

struct ParolaRun {
    let stdout: String
    let stderr: String
    let status: Int32

    var output: String { stdout + stderr }
}

/// Spawns the real binary. The two streams land in files rather than pipes so a chatty child can
/// never fill a pipe buffer while the test is draining the other one. The wait holds no thread and is
/// bounded: a child that stops exiting on its own (a regressed `record` gate listens on the mic until
/// Ctrl-C) has to fail the test, not wedge `swift test`.
func runParola(
    _ arguments: [String],
    environment overrides: [String: String] = [:],
    currentDirectory: URL? = nil,
    timeout: TimeInterval = 120,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> ParolaRun {
    let binary = try #require(parolaBinaryURL)
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("parola-run-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let outURL = scratch.appendingPathComponent("stdout")
    let errURL = scratch.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)

    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    var environment = ProcessInfo.processInfo.environment
    environment["PAROLA_DIAGNOSTICS"] = nil
    environment["PAROLA_LOG_LEVEL"] = nil
    for (key, value) in overrides { environment[key] = value }
    process.environment = environment
    process.standardOutput = try FileHandle(forWritingTo: outURL)
    process.standardError = try FileHandle(forWritingTo: errURL)
    let exited = TestSignal()
    process.terminationHandler = { _ in exited.fire() }
    try process.run()
    let command = "`parola \(arguments.joined(separator: " "))`"
    if await !exited.wait("\(command) to exit", timeout: .seconds(timeout), sourceLocation: sourceLocation) {
        process.terminate()
        if await !exited.wait("\(command) to exit after SIGTERM", timeout: .seconds(5), sourceLocation: sourceLocation) {
            kill(process.processIdentifier, SIGKILL)
            await exited.wait("\(command) to exit after SIGKILL", timeout: .seconds(5), sourceLocation: sourceLocation)
        }
    }

    return ParolaRun(
        stdout: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
        stderr: (try? String(contentsOf: errURL, encoding: .utf8)) ?? "",
        status: exited.fired ? process.terminationStatus : -1
    )
}

/// `HOME` alone does not move `~/Library/Caches`: `NSHomeDirectory()` reads the password database.
/// `CFFIXED_USER_HOME` is the override CoreFoundation honors, so the child writes into the temp
/// home and never touches the real caches directory.
func withTemporaryHome(_ body: (URL, [String: String]) async throws -> Void) async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("parola-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let managed = home.appendingPathComponent("managed.plist")
    try ([:] as NSDictionary).write(to: managed)
    try await body(home, [
        "HOME": home.path,
        "CFFIXED_USER_HOME": home.path,
        "PAROLA_MANAGED_PLIST": managed.path,
    ])
}

func diagnosticsDirectory(in home: URL) -> URL {
    home.appendingPathComponent("Library/Caches/Parola/diagnostics", isDirectory: true)
}

func diagnosticsFiles(in home: URL) -> [URL] {
    let entries = (try? FileManager.default.contentsOfDirectory(
        at: diagnosticsDirectory(in: home),
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )) ?? []
    return entries.filter { $0.lastPathComponent.hasPrefix("parola-") && $0.pathExtension == "jsonl" }
}
