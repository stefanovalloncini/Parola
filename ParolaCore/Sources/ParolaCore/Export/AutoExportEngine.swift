import Foundation

public struct AutoExportRule: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var sourceExtensions: Set<String>
    public var outputFormats: Set<ExportFormat>
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        sourceExtensions: Set<String>,
        outputFormats: Set<ExportFormat>,
        enabled: Bool = true
    ) {
        self.id = id
        self.sourceExtensions = Set(sourceExtensions.map(Self.normalizedExtension))
        self.outputFormats = outputFormats
        self.enabled = enabled
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
    public static func plannedFormats(
        rules: [AutoExportRule],
        sourceExtension: String?
    ) -> [ExportFormat] {
        guard let ext = sourceExtension, !ext.isEmpty else { return [] }
        var seen = Set<ExportFormat>()
        var ordered: [ExportFormat] = []
        for rule in rules where rule.matches(sourceExtension: ext) {
            for format in rule.outputFormats where !seen.contains(format) {
                seen.insert(format)
                ordered.append(format)
            }
        }
        return ordered
    }
}
