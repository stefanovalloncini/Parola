import Foundation

/// `.parola` document — a directory bundle with manifest, transcript JSON, and optional audio.
public struct ParolaDocument: Sendable {
    public struct Manifest: Codable, Sendable, Equatable {
        public static let currentVersion = 1

        public var version: Int
        public var createdAt: Date
        public var originalAudioName: String
        public var modelName: String
        public var language: String
        public var category: EntryCategory
        public var deletedAt: Date?
        public var updatedAt: Date?
        public var lastOpenedAt: Date?
        public var audioFilename: String?
        public var labels: [String]
        public var segmentNotes: [String: String]
        public var pinned: Bool

        public init(
            version: Int = Manifest.currentVersion,
            createdAt: Date = Date(),
            originalAudioName: String,
            modelName: String,
            language: String,
            category: EntryCategory = .transcription,
            deletedAt: Date? = nil,
            updatedAt: Date? = nil,
            lastOpenedAt: Date? = nil,
            audioFilename: String? = nil,
            labels: [String] = [],
            segmentNotes: [String: String] = [:],
            pinned: Bool = false
        ) {
            self.version = version
            self.createdAt = createdAt
            self.originalAudioName = originalAudioName
            self.modelName = modelName
            self.language = language
            self.category = category
            self.deletedAt = deletedAt
            self.updatedAt = updatedAt
            self.lastOpenedAt = lastOpenedAt
            self.audioFilename = audioFilename
            self.labels = labels
            self.segmentNotes = segmentNotes
            self.pinned = pinned
        }

        private enum CodingKeys: String, CodingKey {
            case version
            case createdAt
            case originalAudioName
            case modelName
            case language
            case category
            case deletedAt
            case updatedAt
            case lastOpenedAt
            case audioFilename
            case labels
            case segmentNotes
            case pinned
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            originalAudioName = try c.decode(String.self, forKey: .originalAudioName)
            modelName = try c.decode(String.self, forKey: .modelName)
            language = try c.decode(String.self, forKey: .language)
            category = try c.decodeIfPresent(EntryCategory.self, forKey: .category) ?? .transcription
            deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
            updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
            lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
            audioFilename = try c.decodeIfPresent(String.self, forKey: .audioFilename)
            labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
            segmentNotes = try c.decodeIfPresent([String: String].self, forKey: .segmentNotes) ?? [:]
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(version, forKey: .version)
            try c.encode(createdAt, forKey: .createdAt)
            try c.encode(originalAudioName, forKey: .originalAudioName)
            try c.encode(modelName, forKey: .modelName)
            try c.encode(language, forKey: .language)
            try c.encode(category, forKey: .category)
            try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
            try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
            try c.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
            try c.encodeIfPresent(audioFilename, forKey: .audioFilename)
            if !labels.isEmpty {
                try c.encode(labels, forKey: .labels)
            }
            if !segmentNotes.isEmpty {
                try c.encode(segmentNotes, forKey: .segmentNotes)
            }
            if pinned {
                try c.encode(pinned, forKey: .pinned)
            }
        }
    }

    public var transcript: Transcript
    public var audioURL: URL?
    public var manifest: Manifest

    public init(transcript: Transcript, audioURL: URL?, manifest: Manifest) {
        self.transcript = transcript
        self.audioURL = audioURL
        self.manifest = manifest
    }

    /// Writes a `.parola` bundle atomically. The `.parola` extension is appended if missing.
    /// `audioURL: nil` produces a transcript-only bundle.
    @discardableResult
    public static func write(
        transcript: Transcript,
        audioURL source: URL?,
        to destination: URL,
        category: EntryCategory = .transcription,
        deletedAt: Date? = nil,
        titleOverride: String? = nil
    ) throws -> URL {
        let target = destination.pathExtension == "parola"
            ? destination
            : destination.appendingPathExtension("parola")
        let staging = target.appendingPathExtension("tmp")

        let fm = FileManager.default
        if fm.fileExists(atPath: staging.path) {
            try fm.removeItem(at: staging)
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            var originalAudioName = ""
            var audioFilename: String?
            if let source {
                let audioExt = source.pathExtension.isEmpty ? "wav" : source.pathExtension
                let audioName = "audio.\(audioExt)"
                try fm.copyItem(at: source, to: staging.appendingPathComponent(audioName))
                originalAudioName = source.lastPathComponent
                audioFilename = audioName
            }
            if let titleOverride, !titleOverride.isEmpty {
                originalAudioName = titleOverride
            }

            let manifest = Manifest(
                originalAudioName: originalAudioName,
                modelName: transcript.modelName,
                language: transcript.language,
                category: category,
                deletedAt: deletedAt,
                audioFilename: audioFilename
            )
            try writeJSON(manifest, to: staging.appendingPathComponent("manifest.json"))
            try writeJSON(transcript, to: staging.appendingPathComponent("transcript.json"))

            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        return target
    }

    /// Rewrites the manifest of an existing `.parola` bundle in place. Does not touch audio or transcript files.
    public static func updateManifest(
        at bundleURL: URL,
        transform: (inout Manifest) throws -> Void
    ) throws {
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ParolaError.ioError("Parola document does not exist: \(bundleURL.path)")
        }
        var manifest: Manifest = try readJSON(at: manifestURL)
        try transform(&manifest)
        try writeJSON(manifest, to: manifestURL)
    }

    /// Reads a `.parola` bundle. `audioURL` is nil for transcript-only bundles.
    public static func read(at url: URL) throws -> ParolaDocument {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw ParolaError.ioError("Parola document does not exist: \(url.path)")
        }
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw ParolaError.ioError("Parola document is missing manifest.json: \(url.path)")
        }
        let manifest: Manifest = try readJSON(at: manifestURL)
        guard manifest.version <= Manifest.currentVersion else {
            throw ParolaError.ioError("Parola document version \(manifest.version) is newer than this app understands.")
        }
        let transcript: Transcript = try readJSON(at: url.appendingPathComponent("transcript.json"))

        let audioURL = resolveAudioURL(in: url, manifest: manifest)

        return ParolaDocument(transcript: transcript, audioURL: audioURL, manifest: manifest)
    }

    private static func resolveAudioURL(in bundleURL: URL, manifest: Manifest) -> URL? {
        let fm = FileManager.default
        if let stamped = manifest.audioFilename, !stamped.isEmpty {
            let candidate = bundleURL.appendingPathComponent(stamped)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        let contents = (try? fm.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil)) ?? []
        let audioCandidates = contents
            .filter { $0.lastPathComponent.hasPrefix("audio.") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return audioCandidates.first
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static func readJSON<T: Decodable>(at url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}
