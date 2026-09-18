import ArgumentParser
import Foundation
import ParolaCore

struct Library: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "library",
        abstract: "Inspect and maintain the local Parola library.",
        subcommands: [Verify.self, Stats.self]
    )

    struct Stats: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stats",
            abstract: "Report what the library holds and how long transcribing it took."
        )

        @Flag(help: "Output as JSON.")
        var json: Bool = false

        @Option(name: .long, help: "Library folder to read. Defaults to the app's library.")
        var library: String?

        func run() async throws {
            CLIDiagnostics.installIfWanted(alwaysOn: false)
            let store = library.map {
                LibraryStore(libraryURL: URL(fileURLWithPath: $0, isDirectory: true), extraIndexer: nil)
            } ?? LibraryStore.shared
            let stats = LibraryStatistics.compute(entries: await store.list())
            print(json ? jsonOutput(stats) : LibraryStatsReport.text(stats))
        }

        private func jsonOutput(_ stats: LibraryStatistics) -> String {
            struct ModelRow: Encodable {
                let model: String
                let runs: Int
                let audioSeconds: Double
                let transcriptionSeconds: Double
                let speed: Double?
            }
            struct Payload: Encodable {
                let transcripts: Int
                let audioSeconds: Double
                let transcriptionSeconds: Double
                let words: Int
                let timed: Int
                let timedSince: String?
                let averageSpeed: Double?
                let longestRunSeconds: Double?
                let longestRunEntry: String?
                let last30DaysEntries: Int
                let last30DaysAudioSeconds: Double
                let byCategory: [String: Int]
                let byModel: [ModelRow]
            }
            let payload = Payload(
                transcripts: stats.totals.entries,
                audioSeconds: stats.totals.audioSeconds,
                transcriptionSeconds: stats.totals.transcriptionSeconds,
                words: stats.totals.words,
                timed: stats.timed.count,
                timedSince: stats.timed.since.map { ISO8601DateFormatter().string(from: $0) },
                averageSpeed: stats.averageSpeed,
                longestRunSeconds: stats.longestRun?.seconds,
                longestRunEntry: stats.longestRun?.entryID,
                last30DaysEntries: stats.last30Days.entries,
                last30DaysAudioSeconds: stats.last30Days.audioSeconds,
                byCategory: Dictionary(uniqueKeysWithValues: EntryCategory.allCases.map {
                    ($0.rawValue, stats.totals.count($0))
                }),
                byModel: stats.perModel.map {
                    ModelRow(
                        model: $0.modelName,
                        runs: $0.runs,
                        audioSeconds: $0.audioSeconds,
                        transcriptionSeconds: $0.transcriptionSeconds,
                        speed: $0.speed
                    )
                }
            )
            let data = (try? JSONEncoder.pretty.encode(payload)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

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
            CLIDiagnostics.installIfWanted(alwaysOn: false)
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
