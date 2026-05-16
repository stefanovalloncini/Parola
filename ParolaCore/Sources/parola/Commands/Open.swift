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

    @Option(name: .shortAndLong, help: "Output format: txt | md | srt | vtt | json.")
    var format: ExportFormat = .txt

    @Option(name: .shortAndLong, help: "Write output to this path. Defaults to stdout.")
    var output: String?

    func run() async throws {
        let url = URL(fileURLWithPath: input).resolvingSymlinksInPath()
        let doc = try ParolaDocument.read(at: url)
        let rendered = try Exporters.exporter(for: format).render(doc.transcript)
        if let output {
            try rendered.write(to: URL(fileURLWithPath: output), atomically: true, encoding: .utf8)
        } else {
            print(rendered)
        }
    }
}
