import ArgumentParser
import Foundation
import ParolaCore

struct Diagnostics: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnostics",
        abstract: "Write a report about this Mac and Parola's recent errors, to attach to a bug report."
    )

    @Option(
        name: .shortAndLong,
        help: "Write the report here. Defaults to Parola-Diagnostics-<date>.txt in the current directory."
    )
    var output: String?

    @Flag(name: .long, help: "Print the report instead of writing a file.")
    var stdout: Bool = false

    @Flag(name: .long, help: "Delete the recorded diagnostics once the report is out.")
    var clear: Bool = false

    func validate() throws {
        if stdout, output != nil {
            throw ValidationError("--stdout and --output can't be combined.")
        }
    }

    func run() async throws {
        let directory = DiagnosticsBootstrap.defaultDirectory
        // Listed before the render so the report and --clear see the same files.
        let files = Self.sinkFiles(in: directory)
        if files.isEmpty {
            stderr("No diagnostics recorded.")
        }

        let report = DiagnosticsExport.render(directory: directory, environment: await environment())
        if stdout {
            print(report, terminator: "")
        } else {
            let url = Self.reportURL(output)
            try report.write(to: url, atomically: true, encoding: .utf8)
            print(url.path)
        }

        if clear {
            Self.delete(files)
        }
    }

    private static let knownEngines: [EngineID] = [.whisperKit, .parakeet, .appleSpeech]

    private func environment() async -> DiagnosticsEnvironment {
        let registry = EngineRegistry.shared
        await ParolaCoreBootstrap.registerBuiltInEngines(registry: registry)
        var engines: [EngineID: Bool] = [:]
        for id in Self.knownEngines {
            engines[id] = await registry.isRegistered(id)
        }

        let store = ModelStore.shared
        let models = store.scan().installed.map { model in
            DiagnosticsEnvironment.InstalledModel(
                token: ModelToken(model.name),
                bytes: model.installedURL.flatMap { store.sizeOnDisk(at: $0) }.map { UInt64($0) }
            )
        }

        let library = LibraryStore.shared
        return DiagnosticsEnvironment(
            appVersion: Parola.version,
            engines: engines,
            models: models,
            libraryEntryCount: await library.list().count,
            libraryBytes: await library.sizeOnDisk(),
            features: ParolaCLI.features
        )
    }

    private static func reportURL(_ output: String?) -> URL {
        if let output { return URL(fileURLWithPath: output) }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Parola-Diagnostics-\(today()).txt")
    }

    /// The user's own calendar day, not UTC: an evening run in Rome should not be named tomorrow.
    private static func today() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func sinkFiles(in directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter {
            $0.lastPathComponent.hasPrefix(FileDiagnosticsSink.filePrefix) && $0.pathExtension == "jsonl"
        }
    }

    private static func delete(_ files: [URL]) {
        guard !files.isEmpty else { return }
        var removed = 0
        var bytes = 0
        var live = 0
        for file in files {
            // Unlinking a running app's file would leave it writing into an inode nobody can read.
            guard !FileDiagnosticsSink.isOwnedByLiveProcess(file.lastPathComponent) else {
                live += 1
                continue
            }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            do {
                try FileManager.default.removeItem(at: file)
                removed += 1
                bytes += size
            } catch {
                stderr("Could not delete \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let count = "Deleted \(removed) \(removed == 1 ? "file" : "files")"
        let deleted = removed > 0 ? "\(count) (\(humanBytes(bytes)))" : count
        stderr(live > 0 ? "\(deleted); \(live) still in use." : "\(deleted).")
    }
}
