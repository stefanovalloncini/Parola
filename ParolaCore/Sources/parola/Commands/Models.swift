import ArgumentParser
import Foundation
import ParolaCore

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "Manage local Whisper model cache.",
        subcommands: [List.self, Download.self, Remove.self, Path.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List available and installed models."
        )

        @Flag(help: "Output as JSON.")
        var json: Bool = false

        func run() async throws {
            let store = ModelStore.shared
            let entries = store.catalog()
            let extra = (try? store.installedModels())?.filter { entry in
                !entries.contains { $0.name == entry.name }
            } ?? []
            let all = entries + extra

            if json {
                let data = try JSONEncoder.pretty.encode(all)
                print(String(decoding: data, as: UTF8.self))
                return
            }
            let labelWidth = (all.map { $0.label.count }.max() ?? 0) + 2
            let nameWidth = (all.map { $0.name.count }.max() ?? 0) + 2
            for m in all {
                let mark = m.isInstalled ? "✓" : " "
                let size = m.approximateSizeBytes.map(humanBytes) ?? "—"
                let label = m.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
                let name = m.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                print("\(mark)  \(name)\(label)\(size)")
            }
        }
    }

    struct Download: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "download",
            abstract: "Download a model variant into the local cache."
        )

        @Argument(help: "Model variant name (e.g. openai_whisper-tiny).")
        var name: String

        func run() async throws {
            let store = ModelStore.shared
            if store.isInstalled(name) {
                let path = store.installedURL(for: name).path
                print("Already installed: \(path)")
                return
            }
            stderr("Downloading \(name)…")
            let progress = ProgressReporter(label: name)
            defer { progress.finish() }
            let url = try await store.download(variant: name, progress: { p in progress.update(p) })
            print("Installed at \(url.path)")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Delete a downloaded model."
        )

        @Argument(help: "Model variant name.")
        var name: String

        func run() async throws {
            let store = ModelStore.shared
            try store.delete(variant: name)
            print("Removed \(name).")
        }
    }

    struct Path: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "path",
            abstract: "Print the directory where models are cached."
        )

        func run() async throws {
            let store = ModelStore.shared
            print(store.directory.path)
        }
    }
}
