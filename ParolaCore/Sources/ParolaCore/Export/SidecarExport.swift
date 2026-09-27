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

/// One file to write: what to render and where.
public struct ExportJob: Sendable, Hashable {
    public var spec: ExportSpec
    public var target: URL
    public var owner: String
    public var createsDirectory: Bool

    public init(spec: ExportSpec, target: URL, owner: String, createsDirectory: Bool = false) {
        self.spec = spec
        self.target = target
        self.owner = owner
        self.createsDirectory = createsDirectory
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
            let ext = preset.spec.format.fileExtension
            let names = [
                source.baseName,
                "\(source.baseName).\(slug(preset))",
                "\(source.baseName).\(slug(preset))-\(preset.id.uuidString.prefix(8))",
            ]
            guard let target = names
                .map({ source.directory.appendingPathComponent($0).appendingPathExtension(ext) })
                .first(where: { !seenTargets.contains($0) })
            else { continue }
            seenTargets.insert(target)
            jobs.append(
                ExportJob(
                    spec: preset.spec, target: target, owner: source.owner,
                    createsDirectory: source.createsDirectory
                )
            )
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
        jobs.map { job in
            do {
                let data = try Exporters.exporter(for: job.spec).render(transcript)
                if job.createsDirectory {
                    try FileManager.default.createDirectory(
                        at: job.target.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                }
                let target = claim(job.target, owner: job.owner)
                if target != job.target {
                    ParolaLog.notice(
                        .export, "sidecar target holds a file Parola didn't write; wrote a numbered copy as \(job.spec.format)"
                    )
                }
                try data.write(to: target, options: .atomic)
                OutputMarker.mark(target, owner: job.owner)
                return ExportJobResult(job: job, written: target, error: nil)
            } catch {
                ParolaLog.error(.export, "sidecar export failed as \(job.spec.format)", [.error: .error(error)])
                return ExportJobResult(job: job, written: nil, error: error)
            }
        }
    }

    /// The target itself when it is free or already this owner's; else the first `name (n).ext` that is.
    static func claim(_ target: URL, owner: String) -> URL {
        let stem = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        let folder = target.deletingLastPathComponent()
        var candidate = target
        for number in 2...1000 {
            guard FileManager.default.fileExists(atPath: candidate.path),
                  OutputMarker.owner(of: candidate) != owner else { return candidate }
            candidate = folder.appendingPathComponent("\(stem) (\(number))").appendingPathExtension(ext)
        }
        return folder.appendingPathComponent("\(stem) \(UUID().uuidString.prefix(8))").appendingPathExtension(ext)
    }
}
