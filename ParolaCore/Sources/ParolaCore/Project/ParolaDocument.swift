import Foundation

/// `.parola` document — a directory bundle with manifest, transcript JSON, and audio.
public struct ParolaDocument: Sendable {
    public struct Manifest: Codable, Sendable, Equatable {
        public static let currentVersion = 1

        public var version: Int
        public var createdAt: Date
        public var originalAudioName: String
        public var modelName: String
        public var language: String

        public init(
            version: Int = Manifest.currentVersion,
            createdAt: Date = Date(),
            originalAudioName: String,
            modelName: String,
            language: String
        ) {
            self.version = version
            self.createdAt = createdAt
            self.originalAudioName = originalAudioName
            self.modelName = modelName
            self.language = language
        }
    }

    public var transcript: Transcript
    public var audioURL: URL
    public var manifest: Manifest

    public init(transcript: Transcript, audioURL: URL, manifest: Manifest) {
        self.transcript = transcript
        self.audioURL = audioURL
        self.manifest = manifest
    }

    /// Writes a `.parola` bundle. If `to` doesn't end in `.parola`, the extension is appended.
    @discardableResult
    public static func write(
        transcript: Transcript,
        audioURL source: URL,
        to destination: URL
    ) throws -> URL {
        let target = destination.pathExtension == "parola"
            ? destination
            : destination.appendingPathExtension("parola")

        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        let audioExt = source.pathExtension.isEmpty ? "wav" : source.pathExtension
        let audioName = "audio.\(audioExt)"
        let audioDestination = target.appendingPathComponent(audioName)
        try fm.copyItem(at: source, to: audioDestination)

        let manifest = Manifest(
            originalAudioName: source.lastPathComponent,
            modelName: transcript.modelName,
            language: transcript.language
        )
        try writeJSON(manifest, to: target.appendingPathComponent("manifest.json"))
        try writeJSON(transcript, to: target.appendingPathComponent("transcript.json"))

        return target
    }

    /// Reads a `.parola` bundle.
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
        guard let audioURL = contents.first(where: { $0.lastPathComponent.hasPrefix("audio.") }) else {
            throw ParolaError.ioError("Parola document is missing its audio file.")
        }

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
