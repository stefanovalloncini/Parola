import Foundation

public struct DictationWorkflow: Codable, Sendable, Hashable {
    public var promptID: String?
    public var language: String?

    public init(promptID: String? = nil, language: String? = nil) {
        self.promptID = promptID
        self.language = language
    }

    public var isEmpty: Bool {
        (promptID?.isEmpty ?? true) && (language?.isEmpty ?? true)
    }
}

public enum DictationWorkflowMap {
    public static func decode(legacy data: Data) -> [String: DictationWorkflow] {
        if let nested = try? JSONDecoder().decode([String: DictationWorkflow].self, from: data) {
            return nested.filter { !$0.value.isEmpty }
        }
        if let flat = try? JSONDecoder().decode([String: String].self, from: data) {
            var out: [String: DictationWorkflow] = [:]
            for (bundleID, promptID) in flat where !promptID.isEmpty {
                out[bundleID] = DictationWorkflow(promptID: promptID)
            }
            return out
        }
        return [:]
    }

    public static func encode(_ map: [String: DictationWorkflow]) -> Data {
        let cleaned = map.filter { !$0.value.isEmpty }
        return (try? JSONEncoder().encode(cleaned)) ?? Data("{}".utf8)
    }
}
