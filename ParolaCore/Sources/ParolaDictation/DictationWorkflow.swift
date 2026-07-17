import Foundation

public enum DictationInsertionMode: String, Codable, Sendable, Hashable, CaseIterable {
    case paste
    case keystroke
}

public struct DictationWorkflow: Codable, Sendable, Hashable {
    public var promptID: String?
    public var language: String?
    public var insertion: DictationInsertionMode?
    public var urlPattern: String?

    public init(
        promptID: String? = nil,
        language: String? = nil,
        insertion: DictationInsertionMode? = nil,
        urlPattern: String? = nil
    ) {
        self.promptID = promptID
        self.language = language
        self.insertion = insertion
        self.urlPattern = urlPattern
    }

    public var isEmpty: Bool {
        (promptID?.isEmpty ?? true)
            && (language?.isEmpty ?? true)
            && insertion == nil
            && (urlPattern?.isEmpty ?? true)
    }

    public func matches(url: URL?) -> Bool {
        guard let pattern = urlPattern, !pattern.isEmpty else { return false }
        guard let url else { return false }
        let needle = pattern.lowercased()
        if let host = url.host?.lowercased(), host.contains(needle) { return true }
        return url.absoluteString.lowercased().contains(needle)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promptID = try c.decodeIfPresent(String.self, forKey: .promptID)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        insertion = try c.decodeIfPresent(DictationInsertionMode.self, forKey: .insertion)
        urlPattern = try c.decodeIfPresent(String.self, forKey: .urlPattern)
    }

    private enum CodingKeys: String, CodingKey {
        case promptID
        case language
        case insertion
        case urlPattern
    }
}

public enum DictationWorkflowMap {
    public static func decode(legacy data: Data) -> [String: [DictationWorkflow]] {
        if let arrayShaped = try? JSONDecoder().decode([String: [DictationWorkflow]].self, from: data) {
            return cleaned(arrayShaped)
        }
        if let nested = try? JSONDecoder().decode([String: DictationWorkflow].self, from: data) {
            var out: [String: [DictationWorkflow]] = [:]
            for (bundleID, workflow) in nested where !workflow.isEmpty {
                out[bundleID] = [workflow]
            }
            return out
        }
        if let flat = try? JSONDecoder().decode([String: String].self, from: data) {
            var out: [String: [DictationWorkflow]] = [:]
            for (bundleID, promptID) in flat where !promptID.isEmpty {
                out[bundleID] = [DictationWorkflow(promptID: promptID)]
            }
            return out
        }
        return [:]
    }

    public static func encode(_ map: [String: [DictationWorkflow]]) -> Data {
        let prepared = cleaned(map)
        return (try? JSONEncoder().encode(prepared)) ?? Data("{}".utf8)
    }

    public static func select(
        in map: [String: [DictationWorkflow]],
        for bundleID: String,
        url: URL?
    ) -> DictationWorkflow? {
        guard let entries = map[bundleID], !entries.isEmpty else { return nil }
        if let match = entries.first(where: { $0.matches(url: url) }) {
            return match
        }
        return entries.first(where: { ($0.urlPattern ?? "").isEmpty })
    }

    public static func defaultWorkflow(
        in map: [String: [DictationWorkflow]],
        for bundleID: String
    ) -> DictationWorkflow? {
        map[bundleID]?.first(where: { ($0.urlPattern ?? "").isEmpty })
    }

    public static func urlRules(
        in map: [String: [DictationWorkflow]],
        for bundleID: String
    ) -> [DictationWorkflow] {
        (map[bundleID] ?? []).filter { !($0.urlPattern ?? "").isEmpty }
    }

    /// True when resolving the browser URL could change the outcome of ``select(in:for:url:)``.
    /// Callers use it to skip the AppleScript round-trip when no rule needs a URL.
    public static func hasURLRules(
        in map: [String: [DictationWorkflow]],
        for bundleID: String
    ) -> Bool {
        !urlRules(in: map, for: bundleID).isEmpty
    }

    private static func cleaned(_ map: [String: [DictationWorkflow]]) -> [String: [DictationWorkflow]] {
        var out: [String: [DictationWorkflow]] = [:]
        for (bundleID, workflows) in map {
            let kept = workflows.filter { !$0.isEmpty }
            if !kept.isEmpty { out[bundleID] = kept }
        }
        return out
    }
}
