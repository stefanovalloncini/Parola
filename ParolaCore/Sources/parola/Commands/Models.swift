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
            abstract: "List available and installed models, grouped by category."
        )

        @Flag(help: "Output as JSON.")
        var json: Bool = false

        @Flag(help: "Flat list, ungrouped.")
        var flat: Bool = false

        func run() async throws {
            let store = ModelStore.shared
            let entries = store.catalog()

            if json {
                let data = try JSONEncoder.pretty.encode(entries)
                print(String(decoding: data, as: UTF8.self))
                return
            }

            if flat {
                printFlat(entries)
                return
            }

            let grouped = ModelCatalog.groupedForPicker()
            let nameWidth = (entries.map { $0.name.count }.max() ?? 0) + 2

            for (index, group) in grouped.enumerated() {
                let (category, variants) = group
                if index > 0 { print("") }
                print(category.displayName.uppercased())
                for variant in variants {
                    let installed = entries.first { $0.name == variant.id }?.isInstalled ?? false
                    let mark = installed ? "✓" : " "
                    let name = variant.id.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                    let size = humanBytes(Int(variant.sizeBytes))
                    let langs: String
                    switch variant.languageScope {
                    case .some(.only(let codes)) where codes == ["en"]: langs = "English"
                    case .some(.only): langs = "Subset"
                    default: langs = "Multilingual"
                    }
                    print("\(mark)  \(name)\(variant.displayName) — \(langs), \(size)")
                    print("      \(variant.tagline)")
                }
            }

            let extra = (try? store.installedModels())?.filter { entry in
                !entries.contains { $0.name == entry.name }
            } ?? []
            if !extra.isEmpty {
                print("\nOTHER INSTALLED")
                for m in extra {
                    let name = m.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                    let bytes = m.approximateSizeBytes ?? m.installedURL.flatMap { store.sizeOnDisk(at: $0) }
                    let size = bytes.map(humanBytes) ?? "—"
                    print("✓  \(name)\(m.label) — \(size)")
                }
            }

            let superseded = store.supersededInstalls()
            if !superseded.isEmpty {
                print("\nUNUSED COPIES")
                for old in superseded {
                    let name = old.url.lastPathComponent
                        .padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                    let size = store.sizeOnDisk(at: old.url).map(humanBytes) ?? "—"
                    print("✗  \(name)\(old.displayName) — \(size)")
                    print("      An earlier release installed it here. Run: parola models rm \(old.variantID) --leftovers")
                }
            }
        }

        private func printFlat(_ entries: [ModelInfo]) {
            let labelWidth = (entries.map { $0.label.count }.max() ?? 0) + 2
            let nameWidth = (entries.map { $0.name.count }.max() ?? 0) + 2
            for m in entries {
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
            // Without this the registry is empty and every model takes the generic
            // HuggingFace path instead of its engine's own downloader.
            await ParolaCoreBootstrap.registerBuiltInEngines()
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

        @Argument(help: "Model variant name, or a directory name from the OTHER INSTALLED list.")
        var name: String

        @Flag(help: "Delete only the UNUSED COPIES of this model, keeping the one in use.")
        var leftovers: Bool = false

        func run() async throws {
            let store = ModelStore.shared
            if leftovers {
                try store.deleteLeftovers(variant: name)
                print("Removed the unused copies of \(name).")
                return
            }
            try store.deleteAny(idOrPath: name)
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
