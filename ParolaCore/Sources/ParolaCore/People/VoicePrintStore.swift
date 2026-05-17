import Foundation

public actor VoicePrintStore {
    public static var defaultStorageURL: URL {
        URL.applicationSupportDirectory.appending(path: "Parola/VoicePrints.json")
    }

    private let storageURL: URL
    public private(set) var allPrints: [VoicePrint]

    public init(storageURL: URL = VoicePrintStore.defaultStorageURL) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? JSONDecoder().decode([VoicePrint].self, from: data) {
            self.allPrints = decoded
        } else {
            self.allPrints = []
        }
    }

    @discardableResult
    public func enroll(name: String, embedding: [Float], at date: Date = Date()) -> VoicePrint {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.normalize(trimmed)
        if let index = allPrints.firstIndex(where: { Self.normalize($0.name) == key }) {
            let current = allPrints[index]
            let averaged = VoicePrintMatcher.rollingAverage(
                existing: current.embedding,
                existingCount: current.sampleCount,
                incoming: embedding
            )
            allPrints[index].embedding = averaged
            allPrints[index].sampleCount = current.sampleCount + 1
            allPrints[index].lastSeen = date
            allPrints[index].name = trimmed
            save()
            return allPrints[index]
        }
        let print = VoicePrint(name: trimmed, embedding: embedding, sampleCount: 1, lastSeen: date)
        allPrints.append(print)
        save()
        return print
    }

    public func suggest(for embedding: [Float], threshold: Float = 0.75) -> VoicePrint? {
        VoicePrintMatcher.bestMatch(for: embedding, in: allPrints, threshold: threshold)?.print
    }

    @discardableResult
    public func forget(name: String) -> Bool {
        let key = Self.normalize(name.trimmingCharacters(in: .whitespacesAndNewlines))
        let before = allPrints.count
        allPrints.removeAll { Self.normalize($0.name) == key }
        let changed = allPrints.count != before
        if changed { save() }
        return changed
    }

    private static func normalize(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.localizedLowercase
    }

    private func save() {
        let parent = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(allPrints) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }
}
