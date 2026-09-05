import ArgumentParser
import Foundation
import ParolaCore

struct Engines: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "engines",
        abstract: "Inspect transcription engines and their capabilities.",
        subcommands: [List.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "Print a capability matrix for every registered engine."
        )

        enum Format: String, ExpressibleByArgument, CaseIterable {
            case text
            case markdown
            case json
        }

        @Option(name: .long, help: "Output format (text, markdown, json).")
        var format: Format = .text

        func run() async throws {
            CLIDiagnostics.installIfWanted(alwaysOn: false)
            let rows = await engineRows()
            switch format {
            case .text: printText(rows)
            case .markdown: printMarkdown(rows)
            case .json: try printJSON(rows)
            }
        }

        private func engineRows() async -> [EngineRow] {
            let registry = EngineRegistry.shared
            await ParolaCoreBootstrap.registerBuiltInEngines(registry: registry)
            var rows: [EngineRow] = []
            for id in await registry.registeredEngines() {
                guard let capabilities = await registry.capabilities(for: id) else { continue }
                rows.append(EngineRow(id: id, capabilities: capabilities))
            }
            return rows
        }

        private static let header = ["Engine", "Languages", "Translate", "Prompt", "Word-ts", "Diarize"]

        private func printText(_ rows: [EngineRow]) {
            let body = rows.map(\.cells)
            let widths = (0..<Self.header.count).map { col in
                max(Self.header[col].count, body.map { $0[col].count }.max() ?? 0)
            }
            print(formatRow(Self.header, widths: widths))
            print(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
            for row in body { print(formatRow(row, widths: widths)) }
        }

        private func printMarkdown(_ rows: [EngineRow]) {
            print("| " + Self.header.joined(separator: " | ") + " |")
            print("|" + String(repeating: "---|", count: Self.header.count))
            for row in rows {
                print("| " + row.cells.joined(separator: " | ") + " |")
            }
        }

        private func printJSON(_ rows: [EngineRow]) throws {
            let payload = rows.map(\.json)
            let data = try JSONEncoder.pretty.encode(payload)
            print(String(decoding: data, as: UTF8.self))
        }

        private func formatRow(_ cells: [String], widths: [Int]) -> String {
            cells.enumerated()
                .map { idx, cell in cell.padding(toLength: widths[idx], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
        }
    }
}

private struct EngineRow {
    let id: EngineID
    let capabilities: EngineCapabilities

    var languages: String {
        switch capabilities.supportedLanguages {
        case .all: return "All"
        case .only(let codes):
            if codes == ["en"] { return "English" }
            return codes.sorted().joined(separator: ", ")
        }
    }

    var cells: [String] {
        [
            id.displayName,
            languages,
            capabilities.supportsTranslate ? "yes" : "no",
            capabilities.supportsInitialPrompt ? "yes" : "no",
            capabilities.supportsWordTimestamps ? "yes" : "no",
            capabilities.supportsDiarization ? "yes" : "no",
        ]
    }

    var json: [String: JSONValue] {
        [
            "id": .string(id.rawValue),
            "displayName": .string(id.displayName),
            "supportedLanguages": .string(languages),
            "supportsTranslate": .bool(capabilities.supportsTranslate),
            "supportsInitialPrompt": .bool(capabilities.supportsInitialPrompt),
            "supportsWordTimestamps": .bool(capabilities.supportsWordTimestamps),
            "supportsDiarization": .bool(capabilities.supportsDiarization),
        ]
    }
}

private enum JSONValue: Encodable {
    case string(String)
    case bool(Bool)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        }
    }
}
