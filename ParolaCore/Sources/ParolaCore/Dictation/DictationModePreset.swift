import Foundation

public struct DictationModePreset: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var promptID: UUID?
    public var languageOverride: String?
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        promptID: UUID? = nil,
        languageOverride: String? = nil,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.promptID = promptID
        self.languageOverride = languageOverride
        self.isBuiltIn = isBuiltIn
    }
}

public extension DictationModePreset {
    static let builtIns: [DictationModePreset] = [
        DictationModePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
            name: "Voice",
            promptID: nil,
            isBuiltIn: true
        ),
        DictationModePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!,
            name: "Message",
            promptID: Prompt.builtIns.first { $0.name == "Casual" }?.id,
            isBuiltIn: true
        ),
        DictationModePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!,
            name: "Email",
            promptID: Prompt.builtIns.first { $0.name == "Professional tone" }?.id,
            isBuiltIn: true
        ),
        DictationModePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!,
            name: "Note",
            promptID: Prompt.builtIns.first { $0.name == "Note" }?.id,
            isBuiltIn: true
        ),
        DictationModePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A5")!,
            name: "Code",
            promptID: Prompt.builtIns.first { $0.name == "Code comment" }?.id,
            isBuiltIn: true
        ),
    ]
}
