import Foundation

/// `.parola` document — a directory bundle with manifest, transcript JSON, and optional audio.
public struct ParolaDocument: Sendable {
    public struct Manifest: Codable, Sendable, Equatable {
        public static let currentVersion = 2

        public var version: Int
        public var createdAt: Date
        public var originalAudioName: String
        /// A user-authored display title. When nil, the title is derived from `originalAudioName`
        /// (with the audio extension stripped). Kept separate so titles with dots survive.
        public var title: String?
        public var modelName: String
        public var language: String
        public var category: EntryCategory
        public var deletedAt: Date?
        public var updatedAt: Date?
        public var lastOpenedAt: Date?
        public var audioFilename: String?
        public var labels: [String]
        public var segmentNotes: [String: String]
        public var favoriteSegments: [Int]
        public var pinned: Bool
        /// Media length in seconds. Absent on bundles written before it was recorded.
        public var durationSeconds: Double?
        /// SHA-256 of the imported file's bytes, the key the duplicate check works on. Absent on
        /// bundles written before version 2, and on transcripts imported without their media.
        public var sourceDigest: String?
        /// Wall-clock seconds the engine run took. Absent on bundles written before it was
        /// recorded, and on transcripts that never ran through a file transcription.
        public var transcriptionSeconds: Double?
        /// Words of spoken text, counted when the bundle is written so the statistics page never
        /// has to open transcript.json. Absent on bundles written before it was recorded.
        public var wordCount: Int?
        /// Where the media came from. Bundles written before it was stamped derive it from the model name.
        public var source: EntrySource
        /// Short title and one-line summary written on device when the transcription finished.
        public var aiTitle: String?
        public var shortSummary: String?
        /// Where this transcript has been sent, oldest first.
        public var deliveries: [DeliveryReceipt]

        public init(
            version: Int = Manifest.currentVersion,
            createdAt: Date = Date(),
            originalAudioName: String,
            title: String? = nil,
            modelName: String,
            language: String,
            category: EntryCategory = .transcription,
            deletedAt: Date? = nil,
            updatedAt: Date? = nil,
            lastOpenedAt: Date? = nil,
            audioFilename: String? = nil,
            labels: [String] = [],
            segmentNotes: [String: String] = [:],
            favoriteSegments: [Int] = [],
            pinned: Bool = false,
            durationSeconds: Double? = nil,
            sourceDigest: String? = nil,
            transcriptionSeconds: Double? = nil,
            wordCount: Int? = nil,
            source: EntrySource? = nil,
            aiTitle: String? = nil,
            shortSummary: String? = nil,
            deliveries: [DeliveryReceipt] = []
        ) {
            self.version = version
            self.createdAt = createdAt
            self.originalAudioName = originalAudioName
            self.title = title
            self.modelName = modelName
            self.language = language
            self.category = category
            self.deletedAt = deletedAt
            self.updatedAt = updatedAt
            self.lastOpenedAt = lastOpenedAt
            self.audioFilename = audioFilename
            self.labels = labels
            self.segmentNotes = segmentNotes
            self.favoriteSegments = favoriteSegments
            self.pinned = pinned
            self.durationSeconds = durationSeconds
            self.sourceDigest = sourceDigest
            self.transcriptionSeconds = transcriptionSeconds
            self.wordCount = wordCount
            self.source = source ?? Manifest.derivedSource(modelName: modelName)
            self.aiTitle = aiTitle
            self.shortSummary = shortSummary
            self.deliveries = deliveries
        }

        /// A bundle written before the field kept one trace of a link: the sentinel a caption fetcher stamps.
        static func derivedSource(modelName: String) -> EntrySource {
            modelName.hasPrefix("youtube-") ? .web : .file
        }

        private enum CodingKeys: String, CodingKey {
            case version
            case createdAt
            case originalAudioName
            case title
            case modelName
            case language
            case category
            case deletedAt
            case updatedAt
            case lastOpenedAt
            case audioFilename
            case labels
            case segmentNotes
            case favoriteSegments
            case pinned
            case durationSeconds
            case sourceDigest
            case transcriptionSeconds
            case wordCount
            case source
            case aiTitle
            case shortSummary
            case deliveries
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            originalAudioName = try c.decode(String.self, forKey: .originalAudioName)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            modelName = try c.decode(String.self, forKey: .modelName)
            language = try c.decode(String.self, forKey: .language)
            category = try c.decodeIfPresent(EntryCategory.self, forKey: .category) ?? .transcription
            deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
            updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
            lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
            audioFilename = try c.decodeIfPresent(String.self, forKey: .audioFilename)
            labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
            segmentNotes = try c.decodeIfPresent([String: String].self, forKey: .segmentNotes) ?? [:]
            favoriteSegments = Array(Set(try c.decodeIfPresent([Int].self, forKey: .favoriteSegments) ?? [])).sorted()
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
            sourceDigest = try c.decodeIfPresent(String.self, forKey: .sourceDigest)
            transcriptionSeconds = try c.decodeIfPresent(Double.self, forKey: .transcriptionSeconds)
            wordCount = try c.decodeIfPresent(Int.self, forKey: .wordCount)
            source = try c.decodeIfPresent(EntrySource.self, forKey: .source)
                ?? Manifest.derivedSource(modelName: modelName)
            aiTitle = try c.decodeIfPresent(String.self, forKey: .aiTitle)
            shortSummary = try c.decodeIfPresent(String.self, forKey: .shortSummary)
            deliveries = try c.decodeIfPresent([DeliveryReceipt].self, forKey: .deliveries) ?? []
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(version, forKey: .version)
            try c.encode(createdAt, forKey: .createdAt)
            try c.encode(originalAudioName, forKey: .originalAudioName)
            try c.encodeIfPresent(title, forKey: .title)
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
            if !favoriteSegments.isEmpty {
                try c.encode(Array(Set(favoriteSegments)).sorted(), forKey: .favoriteSegments)
            }
            if pinned {
                try c.encode(pinned, forKey: .pinned)
            }
            try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
            try c.encodeIfPresent(sourceDigest, forKey: .sourceDigest)
            try c.encodeIfPresent(transcriptionSeconds, forKey: .transcriptionSeconds)
            try c.encodeIfPresent(wordCount, forKey: .wordCount)
            try c.encode(source, forKey: .source)
            try c.encodeIfPresent(aiTitle, forKey: .aiTitle)
            try c.encodeIfPresent(shortSummary, forKey: .shortSummary)
            if !deliveries.isEmpty {
                try c.encode(deliveries, forKey: .deliveries)
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
        titleOverride: String? = nil,
        sourceDigest: String? = nil,
        entrySource: EntrySource? = nil
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
            let title = titleOverride.flatMap { $0.isEmpty ? nil : $0 }

            let manifest = Manifest(
                originalAudioName: originalAudioName,
                title: title,
                modelName: transcript.modelName,
                language: transcript.language,
                category: category,
                deletedAt: deletedAt,
                audioFilename: audioFilename,
                durationSeconds: transcript.durationSeconds.flatMap { $0 > 0 ? $0 : nil },
                sourceDigest: source == nil ? nil : sourceDigest,
                transcriptionSeconds: transcript.transcriptionSeconds,
                wordCount: transcript.wordCount,
                source: entrySource
            )
            try writeJSON(manifest, to: staging.appendingPathComponent("manifest.json"))
            // Word timings make transcript.json the biggest file in the bundle; indenting it costs more than it's worth.
            try writeJSON(transcript, to: staging.appendingPathComponent("transcript.json"), pretty: false)

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

        let audioURL = audioURL(in: url, manifest: manifest)

        return ParolaDocument(transcript: transcript, audioURL: audioURL, manifest: manifest)
    }

    static func audioURL(in bundleURL: URL, manifest: Manifest) -> URL? {
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

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL, pretty: Bool = true) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
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
