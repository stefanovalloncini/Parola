import Foundation

/// Where a source's sidecar files go and what the auto-export rules match it on.
public struct SidecarSource: Sendable, Hashable {
    public var fileExtension: String
    public var directory: URL
    public var baseName: String
    /// Whose files these are: a later run for the same owner replaces them, a file anyone else wrote is kept.
    public var owner: String
    /// A folder Parola picked may not exist yet; a source's own folder that is gone (an ejected drive) must not be recreated.
    public var createsDirectory: Bool

    /// Beside the file itself, under its own stem: `clip.mov` gets `clip.srt`.
    public init(besideFile url: URL) {
        fileExtension = url.pathExtension
        directory = url.deletingLastPathComponent()
        baseName = url.deletingPathExtension().lastPathComponent
        owner = url.lastPathComponent
        createsDirectory = false
    }

    /// Into a folder of the caller's choosing, for a source whose own folder nobody opens. The name is
    /// usually an entry title: a slash or colon in it becomes a dash, and a leading dot, which would
    /// hide the file, goes.
    public init(fileExtension: String, folder: URL, baseName: String, owner: String) {
        self.fileExtension = fileExtension
        self.directory = folder
        let cleaned = String(
            baseName
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .drop { $0 == "." }
        )
        self.baseName = cleaned.isEmpty ? "Transcript" : cleaned
        self.owner = owner
        createsDirectory = true
    }
}

/// One file to write: what to render and where. A job's name is `<baseName><nameTail>.<ext>`; when that
/// is taken, the runner numbers the base, `<baseName> (2)<nameTail>.<ext>`, the same for every job of one source.
public struct ExportJob: Sendable, Hashable {
    public var spec: ExportSpec
    public var directory: URL
    public var baseName: String
    public var nameTail: String
    public var owner: String
    public var createsDirectory: Bool

    public var target: URL { target(number: 1) }

    public init(spec: ExportSpec, target: URL, owner: String, createsDirectory: Bool = false) {
        self.init(
            spec: spec,
            directory: target.deletingLastPathComponent(),
            baseName: target.deletingPathExtension().lastPathComponent,
            nameTail: "",
            owner: owner,
            createsDirectory: createsDirectory
        )
    }

    init(spec: ExportSpec, directory: URL, baseName: String, nameTail: String, owner: String, createsDirectory: Bool) {
        self.spec = spec
        self.directory = directory
        self.baseName = baseName
        self.nameTail = nameTail
        self.owner = owner
        self.createsDirectory = createsDirectory
    }

    func target(number: Int) -> URL {
        let base = number == 1 ? baseName : "\(baseName) (\(number))"
        return directory.appendingPathComponent(base + nameTail).appendingPathExtension(spec.format.fileExtension)
    }

    /// The number a file name carries as one of this job's targets, or nil when it isn't one.
    func number(ofFileNamed name: String) -> Int? {
        let suffix = nameTail + "." + spec.format.fileExtension
        guard name.hasPrefix(baseName), name.hasSuffix(suffix), name.count >= baseName.count + suffix.count else {
            return nil
        }
        let middle = name.dropFirst(baseName.count).dropLast(suffix.count)
        if middle.isEmpty { return 1 }
        guard middle.hasPrefix(" ("), middle.hasSuffix(")"), let number = Int(middle.dropFirst(2).dropLast()),
              number >= 2 else { return nil }
        return number
    }
}

/// What came of one ``ExportJob``. `written` differs from the job's target when a file Parola did not
/// write for this owner was already there.
public struct ExportJobResult: Sendable {
    public let job: ExportJob
    public let written: URL?
    public let error: (any Error)?
}

/// Turns preset lists and auto-export rules into the files one source should get.
public enum SidecarExportPlanner {
    /// The presets named directly come first, then those the rules pick for the source; each preset once.
    /// The first preset of a format takes the plain name, and every later one adds its own name:
    /// `clip.srt`, then `clip.SRT-short-reels.srt`.
    public static func plan(
        presets: [ExportPreset],
        rules: [AutoExportRule] = [],
        library: [ExportPreset] = [],
        source: SidecarSource
    ) -> [ExportJob] {
        let ruled = AutoExportEngine.plannedPresets(
            rules: rules, sourceExtension: source.fileExtension, presets: library
        )
        var seenPresets = Set<UUID>()
        var seenTargets = Set<URL>()
        var jobs: [ExportJob] = []
        for preset in presets + ruled where seenPresets.insert(preset.id).inserted {
            let tails = ["", ".\(slug(preset))", ".\(slug(preset))-\(preset.id.uuidString.prefix(8))"]
            guard let job = tails
                .map({
                    ExportJob(
                        spec: preset.spec, directory: source.directory, baseName: source.baseName, nameTail: $0,
                        owner: source.owner, createsDirectory: source.createsDirectory
                    )
                })
                .first(where: { !seenTargets.contains($0.target) })
            else { continue }
            seenTargets.insert(job.target)
            jobs.append(job)
        }
        return jobs
    }

    public static func plan(
        presets: [ExportPreset],
        rules: [AutoExportRule] = [],
        library: [ExportPreset] = [],
        sourceURL: URL
    ) -> [ExportJob] {
        plan(presets: presets, rules: rules, library: library, source: SidecarSource(besideFile: sourceURL))
    }

    /// A preset's name as part of a file name: letters and digits kept, every other run one dash.
    static func slug(_ preset: ExportPreset) -> String {
        var out = ""
        for character in preset.name {
            if character.isLetter || character.isNumber {
                out.append(character)
            } else if !out.isEmpty, out.last != "-" {
                out.append("-")
            }
        }
        while out.last == "-" { out.removeLast() }
        return out.isEmpty ? preset.spec.format.fileExtension : out
    }
}

/// Renders and writes export jobs off the caller's actor, logging every failure.
public enum ExportRunner {
    @concurrent
    public static func run(_ jobs: [ExportJob], transcript: Transcript) async -> [ExportJobResult] {
        var groups: [SourceKey: [Int]] = [:]
        var order: [SourceKey] = []
        for (index, job) in jobs.enumerated() {
            let key = SourceKey(job)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(index)
        }
        var results = [ExportJobResult?](repeating: nil, count: jobs.count)
        for key in order {
            let indices = groups[key] ?? []
            let number = claim(indices.map { jobs[$0] })
            if number > 1 {
                ParolaLog.notice(
                    .export, "sidecar target holds a file Parola didn't write; wrote a numbered copy as \(jobs[indices[0]].spec.format)"
                )
            }
            for index in indices {
                results[index] = write(jobs[index], number: number, transcript: transcript)
            }
            sweepOlderCopies(of: indices.filter { results[$0]?.error == nil }.map { jobs[$0] }, keeping: number)
        }
        return results.compactMap { $0 }
    }

    private static func write(_ job: ExportJob, number: Int, transcript: Transcript) -> ExportJobResult {
        do {
            let data = try Exporters.exporter(for: job.spec).render(transcript)
            if job.createsDirectory {
                try FileManager.default.createDirectory(at: job.directory, withIntermediateDirectories: true)
            }
            let target = job.target(number: number)
            try data.write(to: target, options: .atomic)
            OutputMarker.mark(target, owner: job.owner)
            return ExportJobResult(job: job, written: target, error: nil)
        } catch {
            ParolaLog.error(.export, "sidecar export failed as \(job.spec.format)", [.error: .error(error)])
            return ExportJobResult(job: job, written: nil, error: error)
        }
    }

    /// A source that moved to another number leaves its own files at the old one; only files carrying
    /// its owner's mark are removed, and only once the new copy is written.
    private static func sweepOlderCopies(of written: [ExportJob], keeping number: Int) {
        guard let directory = written.first?.directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for job in written {
            for name in names {
                guard let other = job.number(ofFileNamed: name), other != number else { continue }
                let url = directory.appendingPathComponent(name)
                guard OutputMarker.owner(of: url) == job.owner else { continue }
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    ParolaLog.error(.export, "an older sidecar could not be removed as \(job.spec.format)", [.error: .error(error)])
                }
            }
        }
    }

    /// The jobs of one source share their base name, so all of them take the same number.
    struct SourceKey: Hashable {
        let directory: URL
        let baseName: String
        let owner: String

        init(_ job: ExportJob) {
            directory = job.directory
            baseName = job.baseName
            owner = job.owner
        }
    }

    /// The smallest number at which every one of the source's files is free or already this owner's.
    static func claim(_ group: [ExportJob]) -> Int {
        func usable(_ url: URL, owner: String) -> Bool {
            !FileManager.default.fileExists(atPath: url.path) || OutputMarker.owner(of: url) == owner
        }
        for number in 1...1000 where group.allSatisfy({ usable($0.target(number: number), owner: $0.owner) }) {
            return number
        }
        return 1001
    }
}
