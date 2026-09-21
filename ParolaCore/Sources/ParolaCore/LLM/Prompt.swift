import Foundation

public struct Prompt: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var instructions: String
    public var isBuiltIn: Bool
    public var version: Int
    public var triggerWords: [String]
    public var useSystemInstructions: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        instructions: String,
        isBuiltIn: Bool = false,
        version: Int = 1,
        triggerWords: [String] = [],
        useSystemInstructions: Bool = true
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.isBuiltIn = isBuiltIn
        self.version = version
        self.triggerWords = triggerWords
        self.useSystemInstructions = useSystemInstructions
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, instructions, isBuiltIn, version, triggerWords, useSystemInstructions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        instructions = try c.decode(String.self, forKey: .instructions)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        triggerWords = try c.decodeIfPresent([String].self, forKey: .triggerWords) ?? []
        useSystemInstructions = try c.decodeIfPresent(Bool.self, forKey: .useSystemInstructions) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(instructions, forKey: .instructions)
        try c.encode(isBuiltIn, forKey: .isBuiltIn)
        try c.encode(version, forKey: .version)
        try c.encode(triggerWords, forKey: .triggerWords)
        try c.encode(useSystemInstructions, forKey: .useSystemInstructions)
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
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
            name: "Casual",
            instructions: "Rewrite the text below in a casual, friendly tone. Keep the meaning intact but use plain everyday words and short sentences. Don't add new ideas.",
            isBuiltIn: true,
            version: 1
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!,
            name: "Concise",
            instructions: "Rewrite the text below as tightly as possible. Drop filler words and redundancy. Keep the same meaning. No bullet lists.",
            isBuiltIn: true,
            version: 1
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
            name: "Note",
            instructions: "Turn the dictated text below into a short personal note. One or two lines. No salutation, no signature, no bullets unless the speaker explicitly listed items.",
            isBuiltIn: true,
            version: 1
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
            name: "Code comment",
            instructions: "Turn the dictated text below into a single-line code comment. Lowercase first word unless it's a proper noun. No trailing period. Drop filler.",
            isBuiltIn: true,
            version: 1
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!,
            name: "Assistant",
            instructions: "Answer the user's spoken request below. Reply with the answer only — no preamble, no salutation, no closing. Keep it under 2 sentences unless the question genuinely needs more.",
            isBuiltIn: true,
            version: 1,
            triggerWords: ["assistant", "hey assistant"],
            useSystemInstructions: false
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!,
            name: "Split into paragraphs",
            instructions: "Break the text below into paragraphs by topic, without changing any words.",
            isBuiltIn: true,
            version: 1
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!,
            name: "Highlight key points",
            instructions: "List the key points from the text below, one per line, in the order they appear.",
            isBuiltIn: true,
            version: 1
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000E")!,
            name: "Extract questions",
            instructions: "List every question asked in the text below, one per line, in the order they were asked.",
            isBuiltIn: true,
            version: 1
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000F")!,
            name: "Identify emotions",
            instructions: "Describe the emotional tone of the text below, naming who expressed what and where it shifts.",
            isBuiltIn: true,
            version: 1
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            name: "Generate FAQ",
            instructions: "Write a short FAQ covering the questions a reader of the text below would likely have, with concise answers drawn only from the text.",
            isBuiltIn: true,
            version: 1
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            name: "Extract statistics",
            instructions: "List every number, measurement, date, and statistic mentioned in the text below, one per line, with enough context to understand each one.",
            isBuiltIn: true,
            version: 1
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            name: "Paraphrase",
            instructions: "Rewrite the text below in different words, keeping the same meaning and level of detail.",
            isBuiltIn: true,
            version: 1
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            name: "Create a mind map",
            instructions: "Turn the text below into a Markdown outline, with the central topic as the top heading and supporting ideas nested underneath.",
            isBuiltIn: true,
            version: 1
        ),
    ]

    static let rewritePresets: [Prompt] = {
        let lookup = Dictionary(uniqueKeysWithValues: builtIns.map { ($0.name, $0) })
        let order = ["Professional tone", "Casual", "Concise", "Bullet points"]
        return order.compactMap { lookup[$0] }
    }()
}
