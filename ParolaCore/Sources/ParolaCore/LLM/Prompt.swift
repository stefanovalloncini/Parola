import Foundation

public struct Prompt: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var instructions: String
    public var isBuiltIn: Bool
    public var version: Int

    public init(
        id: UUID = UUID(),
        name: String,
        instructions: String,
        isBuiltIn: Bool = false,
        version: Int = 1
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.isBuiltIn = isBuiltIn
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, instructions, isBuiltIn, version
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        instructions = try c.decode(String.self, forKey: .instructions)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }
}

public extension Prompt {
    static let builtIns: [Prompt] = [
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Cleanup",
            instructions: "Clean up the transcript below. Remove filler words and false starts. Fix obvious transcription errors. Preserve speaker labels and the order of ideas. Don't rephrase, summarise, or change meaning.",
            isBuiltIn: true,
            version: 1
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Translate to English",
            instructions: "Translate the transcript below into natural English. Preserve speaker labels.",
            isBuiltIn: true,
            version: 1
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "Translate to Italian",
            instructions: "Translate the transcript below into natural Italian. Preserve speaker labels.",
            isBuiltIn: true,
            version: 1
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            name: "Professional tone",
            instructions: "Rewrite the transcript below in a professional, clear tone suitable for an email or memo. Keep the structure short.",
            isBuiltIn: true,
            version: 1
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            name: "Bullet points",
            instructions: "Rewrite the transcript below as a tidy bullet list of the main points. Skip filler and small talk.",
            isBuiltIn: true,
            version: 1
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
            name: "Action items",
            instructions: "Extract concrete action items from the transcript below. One per line, in the form: '- [who] should [what] [by when, if mentioned]'. Skip items without a clear action.",
            isBuiltIn: true,
            version: 1
        ),
    ]
}
