import Foundation
import ParolaCore
import ParolaDictation

extension ParolaAutomationServer {
    func mockCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "installMockTranscriber",
                area: .test,
                summary: "Installs a canned transcriber response (segments, partials, progressSeconds, delayMs). Test-mode only.",
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
                    // The session caches the resolved transcriber by engineID; without this a
                    // re-install is silently ignored and the previous canned response keeps running.
                    await ctx.model.unloadTranscriptionSession()
                    return .object([
                        "installed": .bool(true),
                        "engineID": .string(engineRaw),
                    ])
                }
            ),

            AutomationCommand(
                name: "installMockStreamingTranscriber",
                area: .test,
                summary: "Installs a canned streaming-transcriber response (segments, partials, delayMs) or canned failure. Test-mode only.",
                kind: .mutating,
                args: [
                    .init(name: "response", kind: .object, required: false, summary: "Canned transcript JSON"),
                    .init(name: "failure", kind: .object, required: false, summary: "Canned failure JSON"),
                    .init(name: "holdStart", kind: .boolean, required: false, summary: "Keep the take loading its model until releaseMockStreamingStart"),
                ],
                handler: { args, ctx in
                    try requireTestMode(ctx)
                    var response = try buildTranscriberResponse(args: args)
                    await ctx.server.releaseHeldStreamingStart()
                    if try args.optionalBool("holdStart") == true {
                        let gate = MockTranscriberGate()
                        response.gate = gate
                        ctx.server.heldStreamingStart = gate
                    }
                    MockStreamingTranscriberRegistry.shared.install(response)
                    return .object(["installed": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "releaseMockStreamingStart",
                area: .test,
                summary: "Lets a take held by installMockStreamingTranscriber's holdStart finish loading its model. Test-mode only.",
                kind: .mutating,
                handler: { _, ctx in
                    try requireTestMode(ctx)
                    let released = await ctx.server.releaseHeldStreamingStart()
                    return .object(["released": .bool(released)])
                }
            ),

            AutomationCommand(
                name: "installMockMediaFetcher",
                area: .test,
                summary: "Installs a local fixture as the media-fetch result, skipping yt-dlp. Test-mode only.",
                kind: .mutating,
                args: [
                    .init(name: "fixturePath", kind: .string(), required: true, summary: "Absolute path to a local audio file"),
                ],
                handler: { args, ctx in
                    try requireTestMode(ctx)
                    let path = try args.string("fixturePath")
                    ctx.model.linkFetcher = FixtureLinkFetcher(fixtureURL: URL(fileURLWithPath: path))
                    return .object(["installed": .bool(true)])
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
                name: "installMockTranslator",
                area: .test,
                summary: "Installs a translator that never touches the Translation framework. Test-mode only.",
                kind: .mutating,
                args: [
                    .init(name: "mode", kind: .string(enum: MockTranslator.Mode.allCases.map(\.rawValue)), required: true, summary: "How the mock translates"),
                    .init(name: "map", kind: .object, required: false, summary: "Source text to translated text, for the 'map' mode"),
                    .init(name: "delayMs", kind: .integer, required: false, summary: "Milliseconds to hold each batch"),
                ],
                handler: { args, ctx in
                    try requireTestMode(ctx)
                    let modeRaw = try args.string("mode")
                    guard let mode = MockTranslator.Mode(rawValue: modeRaw) else {
                        throw AutomationError.invalidArgs(field: "mode", reason: "unknown mode '\(modeRaw)'")
                    }
                    var map: [String: String] = [:]
                    for (key, value) in args.contains("map") ? try args.object("map") : [:] {
                        guard case .string(let text) = value else {
                            throw AutomationError.invalidArgs(field: "map", reason: "every value must be a string")
                        }
                        map[key] = text
                    }
                    let delayMs = (try args.optionalInt("delayMs")) ?? 0
                    MockTranslatorRegistry.shared.install(MockTranslator(mode: mode, map: map, delayMs: delayMs))
                    return .object([
                        "installed": .bool(true),
                        "mode": .string(modeRaw),
                        "mapCount": .int(map.count),
                        "delayMs": .int(delayMs),
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
                name: "feedTakeLevels",
                area: .test,
                summary: "Plays a WAV fixture's loudness into the running take's level meter until the take lets it go. Test-mode only.",
                kind: .async,
                args: [
                    .init(name: "fixturePath", kind: .string(), required: true, summary: "Absolute path to a WAV fixture"),
                ],
                handler: { args, ctx in
                    try requireTestMode(ctx)
                    let url = URL(fileURLWithPath: try args.string("fixturePath"))
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw AutomationError.invalidArgs(field: "fixturePath", reason: "file does not exist")
                    }
                    guard let meter = ctx.model.recordingLevelMeter else {
                        throw AutomationError.precondition("no take is metering")
                    }
                    let fixture = FixtureAudioSource.make(fixtureURL: url, clock: ContinuousClock())
                    try await fixture.start()
                    let model = ctx.model
                    Task { @MainActor [weak model] in
                        while let model, model.recordingLevelMeter === meter {
                            meter.record(fixture.levelMeter.takePeak())
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                        await fixture.cancel()
                    }
                    return .object(["feeding": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "clearMocks",
                area: .test,
                summary: "Clears installed mocks. Test-mode only.",
                kind: .mutating,
                args: [
                    .init(name: "scope", kind: .string(enum: ["transcriber", "llm", "audio", "media", "translator", "all"]), required: false, summary: "Scope to clear", defaultValue: .string("all")),
                ],
                handler: { args, ctx in
                    try requireTestMode(ctx)
                    let scope = (try args.optionalString("scope")) ?? "all"
                    if scope == "transcriber" || scope == "all" {
                        await MockTranscriberRegistry.shared.clear()
                        MockStreamingTranscriberRegistry.shared.clear()
                        await ctx.server.releaseHeldStreamingStart()
                        CapturedInsertionStore.shared.clear()
                        // The next run would swap the cached mock out anyway; this frees it now.
                        await ctx.model.unloadTranscriptionSession()
                    }
                    if scope == "llm" || scope == "all" {
                        await MockLanguageModelStore.shared.clear()
                    }
                    if scope == "audio" || scope == "all" {
                        await MockAudioSourceRegistry.shared.clear()
                    }
                    if scope == "media" || scope == "all" {
                        ctx.model.linkFetcher = YtDlpLinkFetcher(features: ctx.model.features)
                    }
                    if scope == "translator" || scope == "all" {
                        MockTranslatorRegistry.shared.clear()
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
                        "streamingTranscriber": .bool(MockStreamingTranscriberRegistry.shared.resolve() != nil),
                        "llm": .array(languageModels.map { .string($0) }),
                        "audio": .object(audioObject),
                        "capturedInsertions": .int(CapturedInsertionStore.shared.all().count),
                        "mediaFetcher": .bool(ctx.model.linkFetcher is FixtureLinkFetcher),
                        "translator": MockTranslatorRegistry.shared.resolve().map { .string($0.mode.rawValue) } ?? .null,
                    ])
                }
            ),

            AutomationCommand(
                name: "setStreamingIdleTimeout",
                area: .test,
                summary: "Sets how long a streaming model nothing holds stays loaded. Test-mode only.",
                kind: .mutating,
                args: [
                    .init(name: "seconds", kind: .double, required: true, summary: "Seconds; the app's own value is 600"),
                ],
                handler: { args, ctx in
                    try requireTestMode(ctx)
                    let seconds = try args.double("seconds")
                    guard seconds > 0 else { throw AutomationError.invalidArgs(field: "seconds", reason: "must be positive") }
                    await ctx.model.modelResidency.setStreamingIdleTimeout(.seconds(seconds))
                    return .object(["seconds": .double(seconds)])
                }
            ),

            AutomationCommand(
                name: "getLastInsertedText",
                area: .test,
                summary: "Returns the captured-insertion buffer. Test-mode only.",
                kind: .sync,
                handler: { _, ctx in
                    try requireTestMode(ctx)
                    let last = CapturedInsertionStore.shared.last()
                    let log = CapturedInsertionStore.shared.all()
                    return .object([
                        "lastText": last.map { .string($0) } ?? .null,
                        "log": .array(log.map { .string($0) }),
                    ])
                }
            ),

            AutomationCommand(
                name: "queueSaveDestination",
                area: .test,
                summary: "Queues a save-panel response for the next export. Test-mode only.",
                kind: .mutating,
                args: [
                    .init(name: "path", kind: .string(), required: true, summary: "Absolute path to return as the save destination"),
                ],
                handler: { args, ctx in
                    try requireTestMode(ctx)
                    guard let picker = ctx.model.filePicker as? TestFilePicker else {
                        throw AutomationError.precondition("file picker is not a TestFilePicker")
                    }
                    let path = try args.string("path")
                    await picker.queueSaveResponse(URL(fileURLWithPath: path))
                    return .object(["queued": .bool(true)])
                }
            ),
        ]
    }
}

extension ParolaAutomationServer {
    /// A held mock live take goes on loading; a new install or a clear never leaves one stuck behind its gate.
    @discardableResult
    func releaseHeldStreamingStart() async -> Bool {
        guard let gate = heldStreamingStart else { return false }
        heldStreamingStart = nil
        await gate.open()
        return true
    }
}

@MainActor
func requireTestMode(_ ctx: AutomationContext) throws {
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
    // failure + response composes: canned segments land first, then the failure —
    // that's how a take that dies mid-stream is modelled.
    guard let raw = args.rawValue("response"), case .object(let obj) = raw else {
        return MockTranscriberResponse(failure: failure)
    }
    let segments = try decodeSegments(obj["segments"])
    let partials = decodeStringArray(obj["partials"])
    let progressSeconds = decodeDoubleArray(obj["progressSeconds"])
    let downloadFractions = decodeDoubleArray(obj["downloadFractions"])
    let language = decodeString(obj["language"]) ?? "en"
    let durationSeconds = decodeDouble(obj["durationSeconds"]) ?? 0
    let modelName = decodeString(obj["modelName"]) ?? "mock"
    let delayMs = decodeInt(obj["delayMs"]) ?? 0
    return MockTranscriberResponse(
        segments: segments,
        partials: partials,
        progressSeconds: progressSeconds,
        downloadFractions: downloadFractions,
        language: language,
        durationSeconds: durationSeconds,
        modelName: modelName,
        delayMs: delayMs,
        failure: failure
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
