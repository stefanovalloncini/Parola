import Foundation

/// Where a source's sidecar files go and what the auto-export rules match it on.
public struct SidecarSource: Sendable, Hashable {
    public var fileExtension: String
    public var directory: URL
    public var baseName: String
    /// A folder Parola picked may not exist yet; a source's own folder that is gone (an ejected drive) must not be recreated.
    public var createsDirectory: Bool

    /// Beside the file itself, under its own stem: `clip.mov` gets `clip.srt`.
    public init(besideFile url: URL) {
        fileExtension = url.pathExtension
        directory = url.deletingLastPathComponent()
        baseName = url.deletingPathExtension().lastPathComponent
        createsDirectory = false
    }

    /// Into a folder of the caller's choosing, for a source whose own folder nobody opens. The name is
    /// usually an entry title, so a slash or colon in it becomes a dash.
    public init(fileExtension: String, folder: URL, baseName: String) {
        self.fileExtension = fileExtension
        self.directory = folder
        let cleaned = baseName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseName = cleaned.isEmpty ? "Transcript" : cleaned
        createsDirectory = true
    }
}

/// One file to write: what to render and where.
public struct ExportJob: Sendable, Hashable {
    public var spec: ExportSpec
    public var target: URL
    public var createsDirectory: Bool

    public init(spec: ExportSpec, target: URL, createsDirectory: Bool = false) {
        self.spec = spec
        self.target = target
        self.createsDirectory = createsDirectory
    }
}

/// What came of one ``ExportJob``.
public struct ExportJobResult: Sendable {
    public let job: ExportJob
    public let written: URL?
    public let error: (any Error)?
}

/// Turns preset lists and auto-export rules into the files one source should get.
public enum SidecarExportPlanner {
    /// The presets named directly come first, then those the rules pick for the source; each preset once,
    /// and each target once.
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
            let target = source.directory
                .appendingPathComponent(source.baseName)
                .appendingPathExtension(preset.spec.format.fileExtension)
            guard seenTargets.insert(target).inserted else { continue }
            jobs.append(ExportJob(spec: preset.spec, target: target, createsDirectory: source.createsDirectory))
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
                try data.write(to: job.target, options: .atomic)
                return ExportJobResult(job: job, written: job.target, error: nil)
            } catch {
                ParolaLog.error(.export, "sidecar export failed as \(job.spec.format)", [.error: .error(error)])
                return ExportJobResult(job: job, written: nil, error: error)
            }
        }
    }
}
