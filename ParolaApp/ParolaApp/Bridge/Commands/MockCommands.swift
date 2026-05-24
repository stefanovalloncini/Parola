import Foundation
import ParolaCore

extension ParolaAutomationServer {
    func mockCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "installMockTranscriber",
                area: .test,
                summary: "Installs a canned transcriber response. Test-mode only.",
                kind: .mutating,
                args: [
                    .init(name: "engineID", kind: .string(enum: ["whisperKit", "parakeet", "appleSpeech", "all"]), required: true, summary: "Engine to mock, or 'all'"),
                    .init(name: "response", kind: .object, required: false, summary: "Canned transcript JSON"),
                    .init(name: "failure", kind: .object, required: false, summary: "Canned failure JSON"),
                ],
                handler: { args, ctx in
                    try requireTestMode(ctx)
                    let engineRaw = try args.string("engineID")
                    let engine = parseEngineID(engineRaw)
                    let response = try buildTranscriberResponse(args: args)
                    await MockTranscriberRegistry.shared.install(engineID: engine, response: response)
                    return .object([
                        "installed": .bool(true),
                        "engineID": .string(engineRaw),
                    ])
                }
            ),

            AutomationCommand(
                name: "installMockLanguageModel",
                area: .test,
                summary: "Installs a canned language model response. Test-mode only.",
                kind: .mutating,
                args: [
                    .init(name: "provider", kind: .string(enum: ["openAI", "anthropic", "groq", "cerebras", "ollama", "foundation", "all"]), required: true, summary: "LLM provider to mock, or 'all'"),
                    .init(name: "response", kind: .object, required: false, summary: "Canned response JSON"),
                    .init(name: "failure", kind: .object, required: false, summary: "Canned failure JSON"),
                ],
                handler: { args, ctx in
                    try requireTestMode(ctx)
                    let providerRaw = try args.string("provider")
                    let provider = parseProvider(providerRaw)
                    let response = try buildLanguageModelResponse(args: args)
                    await MockLanguageModelStore.shared.install(provider: provider, response: response)
                    return .object([
                        "installed": .bool(true),
                        "provider": .string(providerRaw),
                    ])
                }
            ),

            AutomationCommand(
                name: "installMockAudioInput",
                area: .test,
                summary: "Swaps live audio sources for a WAV fixture. Test-mode only.",
                kind: .mutating,
                args: [
                    .init(name: "kind", kind: .string(enum: ["mic", "system", "all"]), required: true, summary: "Source to swap, or 'all'"),
                    .init(name: "fixturePath", kind: .string(), required: true, summary: "Absolute path to a WAV fixture"),
                ],
                handler: { args, ctx in
                    try requireTestMode(ctx)
                    let kindRaw = try args.string("kind")
                    let kind = parseAudioKind(kindRaw)
                    let path = try args.string("fixturePath")
                    let url = URL(fileURLWithPath: path)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw AutomationError.invalidArgs(field: "fixturePath", reason: "file does not exist")
                    }
                    await MockAudioSourceRegistry.shared.install(kind: kind, fixtureURL: url)
                    return .object([
                        "installed": .bool(true),
                        "kind": .string(kindRaw),
                        "fixturePath": .string(path),
                    ])
                }
            ),

            AutomationCommand(
                name: "clearMocks",
                area: .test,
                summary: "Clears installed mocks. Test-mode only.",
                kind: .mutating,
                args: [
                    .init(name: "scope", kind: .string(enum: ["transcriber", "llm", "audio", "all"]), required: false, summary: "Scope to clear", defaultValue: .string("all")),
                ],
                handler: { args, ctx in
                    try requireTestMode(ctx)
                    let scope = (try args.optionalString("scope")) ?? "all"
                    if scope == "transcriber" || scope == "all" {
                        await MockTranscriberRegistry.shared.clear()
                    }
                    if scope == "llm" || scope == "all" {
                        await MockLanguageModelStore.shared.clear()
                    }
                    if scope == "audio" || scope == "all" {
                        await MockAudioSourceRegistry.shared.clear()
                    }
                    return .object([
                        "cleared": .bool(true),
                        "scope": .string(scope),
                    ])
                }
            ),

            AutomationCommand(
                name: "listMocks",
                area: .test,
                summary: "Lists currently installed mocks. Test-mode only.",
                kind: .sync,
                handler: { _, ctx in
                    try requireTestMode(ctx)
                    let transcribers = await MockTranscriberRegistry.shared.list()
                    let languageModels = await MockLanguageModelStore.shared.list()
                    let audioMap = await MockAudioSourceRegistry.shared.list()
                    var audioObject: [String: AutomationValue] = [:]
                    for (k, v) in audioMap { audioObject[k] = .string(v) }
                    return .object([
                        "transcriber": .array(transcribers.map { .string($0) }),
                        "llm": .array(languageModels.map { .string($0) }),
                        "audio": .object(audioObject),
                    ])
                }
            ),
        ]
    }
}

@MainActor
private func requireTestMode(_ ctx: AutomationContext) throws {
    guard ctx.model.mode == .test else {
        throw AutomationError.precondition("only available in --test-mode")
    }
}

private func parseEngineID(_ raw: String) -> EngineID? {
    switch raw {
    case "all": return nil
    case "whisperKit": return .whisperKit
    case "parakeet": return .parakeet
    case "appleSpeech": return .appleSpeech
    default: return EngineID(raw)
    }
}

private func parseProvider(_ raw: String) -> MockLanguageModelStore.Provider? {
    switch raw {
    case "all": return nil
    case "openAI": return .openAI
    case "anthropic": return .anthropic
    case "groq": return .groq
    case "cerebras": return .cerebras
    case "ollama": return .ollama
    case "foundation": return .foundation
    default: return nil
    }
}

private func parseAudioKind(_ raw: String) -> MockAudioSourceRegistry.Kind? {
    switch raw {
    case "all": return nil
    case "mic": return .mic
    case "system": return .system
    default: return nil
    }
}

private func buildTranscriberResponse(args: AutomationArgs) throws -> MockTranscriberResponse {
    let failure = try decodeTranscriberFailure(args.rawValue("failure"))
    if failure != nil {
        return MockTranscriberResponse(failure: failure)
    }
    guard let raw = args.rawValue("response"), case .object(let obj) = raw else {
        return MockTranscriberResponse()
    }
    let segments = try decodeSegments(obj["segments"])
    let partials = decodeStringArray(obj["partials"])
    let downloadFractions = decodeDoubleArray(obj["downloadFractions"])
    let language = decodeString(obj["language"]) ?? "en"
    let durationSeconds = decodeDouble(obj["durationSeconds"]) ?? 0
    let modelName = decodeString(obj["modelName"]) ?? "mock"
    let delayMs = decodeInt(obj["delayMs"]) ?? 0
    return MockTranscriberResponse(
        segments: segments,
        partials: partials,
        downloadFractions: downloadFractions,
        language: language,
        durationSeconds: durationSeconds,
        modelName: modelName,
        delayMs: delayMs
    )
}

private func buildLanguageModelResponse(args: AutomationArgs) throws -> MockLanguageModelResponse {
    let failure = try decodeLanguageModelFailure(args.rawValue("failure"))
    if failure != nil {
        return MockLanguageModelResponse(failure: failure)
    }
    guard let raw = args.rawValue("response"), case .object(let obj) = raw else {
        return MockLanguageModelResponse()
    }
    let text = decodeString(obj["text"]) ?? ""
    let streamChunks = decodeOptionalStringArray(obj["streamChunks"])
    let delayMs = decodeInt(obj["delayMs"]) ?? 0
    return MockLanguageModelResponse(text: text, streamChunks: streamChunks, delayMs: delayMs)
}

private func decodeTranscriberFailure(_ value: AutomationValue?) throws -> MockTranscriberFailure? {
    guard let value, case .object(let obj) = value else { return nil }
    guard let codeRaw = decodeString(obj["code"]) else {
        throw AutomationError.invalidArgs(field: "failure.code", reason: "missing required string")
    }
    guard let code = MockTranscriberFailure.Code(rawValue: codeRaw) else {
        throw AutomationError.invalidArgs(field: "failure.code", reason: "unknown code '\(codeRaw)'")
    }
    let message = decodeString(obj["message"]) ?? ""
    return MockTranscriberFailure(code: code, message: message)
}

private func decodeLanguageModelFailure(_ value: AutomationValue?) throws -> MockLanguageModelFailure? {
    guard let value, case .object(let obj) = value else { return nil }
    guard let codeRaw = decodeString(obj["code"]) else {
        throw AutomationError.invalidArgs(field: "failure.code", reason: "missing required string")
    }
    guard let code = MockLanguageModelFailure.Code(rawValue: codeRaw) else {
        throw AutomationError.invalidArgs(field: "failure.code", reason: "unknown code '\(codeRaw)'")
    }
    let message = decodeString(obj["message"]) ?? ""
    return MockLanguageModelFailure(code: code, message: message)
}

private func decodeSegments(_ value: AutomationValue?) throws -> [TranscriptSegmentSeed] {
    guard let value, case .array(let items) = value else { return [] }
    return items.compactMap { item -> TranscriptSegmentSeed? in
        guard case .object(let obj) = item else { return nil }
        guard let start = decodeDouble(obj["start"]),
              let end = decodeDouble(obj["end"]),
              let text = decodeString(obj["text"]) else { return nil }
        let speaker = decodeString(obj["speaker"])
        let words = decodeWords(obj["words"])
        return TranscriptSegmentSeed(start: start, end: end, text: text, speaker: speaker, words: words)
    }
}

private func decodeWords(_ value: AutomationValue?) -> [WordTimingSeed]? {
    guard let value, case .array(let items) = value else { return nil }
    let seeds = items.compactMap { item -> WordTimingSeed? in
        guard case .object(let obj) = item else { return nil }
        guard let word = decodeString(obj["word"]),
              let start = decodeDouble(obj["start"]),
              let end = decodeDouble(obj["end"]) else { return nil }
        let probability = decodeDouble(obj["probability"]) ?? 1.0
        let speaker = decodeString(obj["speaker"])
        return WordTimingSeed(word: word, start: start, end: end, probability: probability, speaker: speaker)
    }
    return seeds.isEmpty ? nil : seeds
}

private func decodeString(_ value: AutomationValue?) -> String? {
    guard let value, case .string(let s) = value else { return nil }
    return s
}

private func decodeDouble(_ value: AutomationValue?) -> Double? {
    guard let value else { return nil }
    switch value {
    case .double(let d): return d
    case .int(let i): return Double(i)
    default: return nil
    }
}

private func decodeInt(_ value: AutomationValue?) -> Int? {
    guard let value else { return nil }
    switch value {
    case .int(let i): return i
    case .double(let d) where d.rounded() == d: return Int(d)
    default: return nil
    }
}

private func decodeStringArray(_ value: AutomationValue?) -> [String] {
    guard let value, case .array(let items) = value else { return [] }
    return items.compactMap { decodeString($0) }
}

private func decodeOptionalStringArray(_ value: AutomationValue?) -> [String]? {
    guard let value, case .array(let items) = value else { return nil }
    let out = items.compactMap { decodeString($0) }
    return out.isEmpty ? nil : out
}

private func decodeDoubleArray(_ value: AutomationValue?) -> [Double] {
    guard let value, case .array(let items) = value else { return [] }
    return items.compactMap { decodeDouble($0) }
}
