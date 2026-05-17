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

        public init(
            version: Int = Manifest.currentVersion,
            createdAt: Date = Date(),
            originalAudioName: String,
            modelName: String,
            language: String,
            category: EntryCategory = .transcription,
            deletedAt: Date? = nil,
            updatedAt: Date? = nil
        ) {
            self.version = version
            self.createdAt = createdAt
            self.originalAudioName = originalAudioName
            self.modelName = modelName
            self.language = language
            self.category = category
            self.deletedAt = deletedAt
            self.updatedAt = updatedAt
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

    /// Writes a `.parola` bundle. If `to` doesn't end in `.parola`, the extension is appended.
    /// Pass `audioURL: nil` for transcript-only bundles (live recordings without saved audio).
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

        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        var originalAudioName = ""
        if let source {
            let audioExt = source.pathExtension.isEmpty ? "wav" : source.pathExtension
            let audioName = "audio.\(audioExt)"
            try fm.copyItem(at: source, to: target.appendingPathComponent(audioName))
            originalAudioName = source.lastPathComponent
        }
        if let titleOverride, !titleOverride.isEmpty {
            originalAudioName = titleOverride
        }

        let manifest = Manifest(
            originalAudioName: originalAudioName,
            modelName: transcript.modelName,
            language: transcript.language,
            category: category,
            deletedAt: deletedAt
        )
        try writeJSON(manifest, to: target.appendingPathComponent("manifest.json"))
        try writeJSON(transcript, to: target.appendingPathComponent("transcript.json"))

        return target
    }

    /// Rewrites the manifest of an existing `.parola` bundle in place.
    /// Used by soft-delete, restore, and category-edit flows — no audio or transcript I/O.
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
        let manifest: Manifest = try readJSON(at: url.appendingPathComponent("manifest.json"))
        guard manifest.version <= Manifest.currentVersion else {
            throw ParolaError.ioError("Parola document version \(manifest.version) is newer than this app understands.")
        }
        let transcript: Transcript = try readJSON(at: url.appendingPathComponent("transcript.json"))

        let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        let audioURL = contents.first(where: { $0.lastPathComponent.hasPrefix("audio.") })

        return ParolaDocument(transcript: transcript, audioURL: audioURL, manifest: manifest)
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
