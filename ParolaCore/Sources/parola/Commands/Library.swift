import ArgumentParser
import Foundation
import ParolaCore

struct Library: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "library",
        abstract: "Inspect and maintain the local Parola library.",
        subcommands: [Verify.self]
    )

    struct Verify: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "verify",
            abstract: "Walk every .parola bundle and report half-written or invalid ones."
        )

        @Flag(help: "Output as JSON.")
        var json: Bool = false

        @Option(name: .long, help: "Library folder to verify. Defaults to the app's library.")
        var library: String?

        func run() async throws {
            let store = library.map {
                LibraryStore(libraryURL: URL(fileURLWithPath: $0, isDirectory: true), extraIndexer: nil)
            } ?? LibraryStore.shared
            let report = await store.verify()
            if json {
                print(jsonOutput(report))
            } else {
                print("Healthy: \(report.healthy.count)")
                print("Problems: \(report.problems.count)")
                for problem in report.problems {
                    print("  \(problem.bundleURL.lastPathComponent): \(describe(problem.issue))")
                }
            }
            if !report.problems.isEmpty {
                throw ExitCode(1)
            }
        }

        private func describe(_ issue: LibraryStore.VerificationReport.Issue) -> String {
            switch issue {
            case .missingManifest:    return "missing manifest.json"
            case .unreadableManifest: return "manifest.json could not be decoded"
            case .missingTranscript:  return "missing transcript.json"
            case .versionTooNew(let v): return "schema version \(v) is newer than this app"
            }
        }

        private func jsonOutput(_ report: LibraryStore.VerificationReport) -> String {
            struct Item: Encodable {
                let bundle: String
                let issue: String
            }
            let items = report.problems.map {
                Item(bundle: $0.bundleURL.path, issue: describe($0.issue))
            }
            struct Payload: Encodable {
                let healthy: Int
                let problems: [Item]
            }
            let payload = Payload(healthy: report.healthy.count, problems: items)
            let data = (try? JSONEncoder.pretty.encode(payload)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }
}
