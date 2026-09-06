import Foundation

/// What the export header reports about the process that produced it. The renderer reads nothing
/// on its own, so a frontend fills in what it can answer and leaves the rest nil.
public struct DiagnosticsEnvironment: Sendable {
    public enum Permission: String, Sendable {
        case granted
        case denied
        case undetermined
    }

    public struct InstalledModel: Sendable {
        public let token: ModelToken
        public let bytes: UInt64?

        public init(token: ModelToken, bytes: UInt64?) {
            self.token = token
            self.bytes = bytes
        }
    }

    public var appVersion: String?
    public var appBuild: String?
    public var osVersion: String
    public var arch: String
    public var physicalMemoryBytes: UInt64
    public var localeIdentifier: String
    public var microphone: Permission?
    public var screenRecording: Permission?
    public var systemAudio: Permission?
    public var accessibility: Permission?
    public var engines: [EngineID: Bool]
    public var models: [InstalledModel]
    public var libraryEntryCount: Int?
    public var libraryBytes: UInt64?
    public var features: FeatureSet

    public init(
        appVersion: String? = nil,
        appBuild: String? = nil,
        osVersion: String = DiagnosticsEnvironment.currentOSVersion,
        arch: String = DiagnosticsEnvironment.currentArchitecture,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        localeIdentifier: String = DiagnosticsEnvironment.currentLocaleIdentifier,
        microphone: Permission? = nil,
        screenRecording: Permission? = nil,
        systemAudio: Permission? = nil,
        accessibility: Permission? = nil,
        engines: [EngineID: Bool] = [:],
        models: [InstalledModel] = [],
        libraryEntryCount: Int? = nil,
        libraryBytes: UInt64? = nil,
        features: FeatureSet = .all
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.arch = arch
        self.physicalMemoryBytes = physicalMemoryBytes
        self.localeIdentifier = localeIdentifier
        self.microphone = microphone
        self.screenRecording = screenRecording
        self.systemAudio = systemAudio
        self.accessibility = accessibility
        self.engines = engines
        self.models = models
        self.libraryEntryCount = libraryEntryCount
        self.libraryBytes = libraryBytes
        self.features = features
    }

    public static var currentOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var text = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { text += ".\(version.patchVersion)" }
        if let build = osBuild() { text += " (\(build))" }
        return text
    }

    public static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// Language and region only — the full identifier carries calendar and currency preferences
    /// that say more about the person than about the bug.
    public static var currentLocaleIdentifier: String {
        let locale = Locale.current
        guard let language = locale.language.languageCode?.identifier else { return "unknown" }
        guard let region = locale.region?.identifier else { return language }
        return "\(language)_\(region)"
    }

    private static func osBuild() -> String? {
        let text = ProcessInfo.processInfo.operatingSystemVersionString
        guard let marker = text.range(of: "Build ") else { return nil }
        let build = text[marker.upperBound...].prefix { $0.isLetter || $0.isNumber }
        return build.isEmpty ? nil : String(build)
    }
}

/// One line read back from a sink file — not a `LogRecord`, whose `init` and runtime message stay closed.
struct ExportedRecord: Sendable {
    let timestamp: Date?
    let timestampText: String
    let level: String
    let subsystem: String
    let category: String
    let message: String
    let fields: [String: String]
}

struct DiagnosticsReading: Sendable {
    var records: [ExportedRecord] = []
    var skippedLines: Int = 0
    var skippedFiles: Int = 0
}

public enum DiagnosticsExport {
    /// Reads every sink file in `directory` and renders the plain-text diagnostics report. Walks
    /// the whole directory, so callers keep it off the main thread.
    public static func render(
        directory: URL,
        environment: DiagnosticsEnvironment,
        generatedAt: Date = Date()
    ) -> String {
        render(reading: read(directory: directory), environment: environment, generatedAt: generatedAt)
    }

    static func read(directory: URL) -> DiagnosticsReading {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return DiagnosticsReading() }

        var reading = DiagnosticsReading()
        let files = entries
            .filter {
                $0.lastPathComponent.hasPrefix(FileDiagnosticsSink.filePrefix)
                    && $0.pathExtension == "jsonl"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            guard let data = try? Data(contentsOf: file) else {
                reading.skippedFiles += 1
                continue
            }
            // A crashing session's file may end mid-character; decode leniently and count the broken line.
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if let record = decode(line: line) {
                    reading.records.append(record)
                } else {
                    reading.skippedLines += 1
                }
            }
        }
        reading.records = sortedByTimestamp(reading.records)
        return reading
    }

    private static func decode(line: Substring) -> ExportedRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let schemaVersion = object["schemaVersion"] as? Int,
              schemaVersion <= FileDiagnosticsSink.schemaVersion,
              let timestamp = object["ts"] as? String,
              let level = object["level"] as? String,
              let category = object["category"] as? String,
              let message = object["message"] as? String
        else { return nil }
        return ExportedRecord(
            timestamp: parseTimestamp(timestamp),
            timestampText: timestamp,
            level: level,
            subsystem: object["subsystem"] as? String ?? "",
            category: category,
            message: message,
            fields: object["fields"] as? [String: String] ?? [:]
        )
    }

    /// Ties every record to its read order, so equal/unparsable timestamps keep a stable position.
    private static func sortedByTimestamp(_ records: [ExportedRecord]) -> [ExportedRecord] {
        records.enumerated().sorted { lhs, rhs in
            switch (lhs.element.timestamp, rhs.element.timestamp) {
            case let (left?, right?):
                return left == right ? lhs.offset < rhs.offset : left < right
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(text)
    }
}
