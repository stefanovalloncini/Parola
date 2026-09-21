import Foundation

public struct AutoExportRule: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var sourceExtensions: Set<String>
    public var presetIDs: [UUID]
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        sourceExtensions: Set<String>,
        presetIDs: [UUID],
        enabled: Bool = true
    ) {
        self.id = id
        self.sourceExtensions = Set(sourceExtensions.map(Self.normalizedExtension))
        self.presetIDs = presetIDs
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceExtensions, presetIDs, enabled, outputFormats
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourceExtensions = Set(
            (try c.decodeIfPresent(Set<String>.self, forKey: .sourceExtensions) ?? []).map(Self.normalizedExtension)
        )
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        if let ids = try c.decodeIfPresent([UUID].self, forKey: .presetIDs) {
            presetIDs = ids
        } else {
            let legacy = try c.decodeIfPresent(Set<ExportFormat>.self, forKey: .outputFormats) ?? []
            presetIDs = ExportFormat.allCases
                .filter(legacy.contains)
                .compactMap { ExportPreset.builtIn(for: $0)?.id }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceExtensions, forKey: .sourceExtensions)
        try c.encode(presetIDs, forKey: .presetIDs)
        try c.encode(enabled, forKey: .enabled)
    }

    /// Users type ".wav" or "*.wav" as often as "wav"; matching is on the bare extension.
    public static func normalizedExtension(_ raw: String) -> String {
        var ext = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if ext.hasPrefix("*.") { ext.removeFirst(2) }
        while ext.hasPrefix(".") { ext.removeFirst() }
        return ext
    }

    /// An empty extension set matches every source, mirroring the "any" label in the rules UI.
    public func matches(sourceExtension: String) -> Bool {
        enabled && (sourceExtensions.isEmpty || sourceExtensions.contains(sourceExtension.lowercased()))
    }
}

public enum AutoExportEngine {
    public static func plannedPresets(
        rules: [AutoExportRule],
        sourceExtension: String?,
        presets: [ExportPreset]
    ) -> [ExportPreset] {
        guard let ext = sourceExtension, !ext.isEmpty else { return [] }
        let byID = Dictionary(presets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        var ordered: [ExportPreset] = []
        for rule in rules where rule.matches(sourceExtension: ext) {
            for id in rule.presetIDs where !seen.contains(id) {
                guard let preset = byID[id] else { continue }
                seen.insert(id)
                ordered.append(preset)
            }
        }
        return ordered
    }
}
