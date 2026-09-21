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
            let calendar = Calendar.current
            let stats = LibraryStatistics.compute(entries: await store.list(), calendar: calendar)
            print(json ? jsonOutput(stats, calendar: calendar) : LibraryStatsReport.text(stats))
        }

        private func jsonOutput(_ stats: LibraryStatistics, calendar: Calendar) -> String {
            struct ModelRow: Encodable {
                let model: String
                let runs: Int
                let audioSeconds: Double
                let transcriptionSeconds: Double
                let speed: Double?
            }
            struct ActivityDay: Encodable {
                let day: String
                let entries: Int
                let audioSeconds: Double
            }
            struct ActivityMonth: Encodable {
                let month: String
                let entries: Int
                let audioSeconds: Double
            }
            struct Payload: Encodable {
                let transcripts: Int
                let audioSeconds: Double
                let transcriptionSeconds: Double
                let words: Int
                let wordsCountedFor: Int
                let timed: Int
                let timedSince: String?
                let averageSpeed: Double?
                let longestRunSeconds: Double?
                let longestRunEntry: String?
                let longestTranscriptSeconds: Double?
                let longestTranscriptEntry: String?
                let fastestRunSpeed: Double?
                let fastestRunEntry: String?
                let last30DaysEntries: Int
                let last30DaysAudioSeconds: Double
                let byCategory: [String: Int]
                let byModel: [ModelRow]
                let dailyActivity: [ActivityDay]
                let monthlyActivity: [ActivityMonth]
            }
            let day = { (date: Date) -> String in
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            }
            let month = { (date: Date) -> String in
                let parts = calendar.dateComponents([.year, .month], from: date)
                return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
            }
            let payload = Payload(
                transcripts: stats.totals.entries,
                audioSeconds: stats.totals.audioSeconds,
                transcriptionSeconds: stats.totals.transcriptionSeconds,
                words: stats.totals.words,
                wordsCountedFor: stats.totals.wordsCountedFor,
                timed: stats.timed.count,
                timedSince: stats.timed.since.map { ISO8601DateFormatter().string(from: $0) },
                averageSpeed: stats.averageSpeed,
                longestRunSeconds: stats.longestRun?.seconds,
                longestRunEntry: stats.longestRun?.entryID,
                longestTranscriptSeconds: stats.longestTranscript?.seconds,
                longestTranscriptEntry: stats.longestTranscript?.entryID,
                fastestRunSpeed: stats.fastestRun?.speed,
                fastestRunEntry: stats.fastestRun?.entryID,
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
                },
                dailyActivity: stats.dailyActivity.map {
                    ActivityDay(day: day($0.start), entries: $0.entries, audioSeconds: $0.audioSeconds)
                },
                monthlyActivity: stats.monthlyActivity.map {
                    ActivityMonth(month: month($0.start), entries: $0.entries, audioSeconds: $0.audioSeconds)
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
