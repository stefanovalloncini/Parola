import ArgumentParser
import Foundation
import ParolaCore

struct Open: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a saved .parola document and re-export its transcript."
    )

    @Argument(help: "Path to a .parola bundle.")
    var input: String

    @Option(name: .shortAndLong, help: "Output format: txt | md | html | docx | pdf | csv | tsv | srt | vtt | json | jsonl | fcpxml.")
    var format: ExportFormat = .txt

    @Option(name: .shortAndLong, help: "Write output to this path. Defaults to stdout.")
    var output: String?

    func run() async throws {
        let url = URL(fileURLWithPath: input).resolvingSymlinksInPath()
        let doc = try ParolaDocument.read(at: url)
        let exporter = Exporters.exporter(for: format)
        if let output {
            try exporter.render(doc.transcript).write(to: URL(fileURLWithPath: output), options: .atomic)
        } else {
            print(try exporter.renderText(doc.transcript))
        }
    }
}
