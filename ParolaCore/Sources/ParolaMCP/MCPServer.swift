import Foundation
import ParolaCore

/// JSON-RPC handler for the Parola MCP server. Owns the engine session and proxies app-bridge calls.
public actor MCPServer {
    public static let supportedProtocolVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]
    public static let preferredProtocolVersion: String = "2025-06-18"

    private let session: TranscriptionSession
    private let modelStore: ModelStore
    private let libraryStore: LibraryStore
    private let bridge: any BridgeProtocol
    private let features: FeatureSet
    private(set) var shouldExit: Bool = false

    /// `libraryStore` carries no default on purpose: the only store a missing argument could pick
    /// is the user's real library, and a test that inherited it would rewrite their manifests.
    public init(
        session: TranscriptionSession = TranscriptionSession(),
        modelStore: ModelStore = .shared,
        libraryStore: LibraryStore,
        bridge: any BridgeProtocol = BridgeClient(),
        features: FeatureSet = .resolveFromAppDomain()
    ) {
        self.session = session
        self.modelStore = modelStore
        self.libraryStore = libraryStore
        self.bridge = bridge
        self.features = features
    }

    public func handle(
        _ request: JSONRPCRequest,
        notify: @escaping @Sendable (JSONRPCNotification) async -> Void = { _ in }
    ) async throws -> JSONRPCResponse? {
        switch request.method {
        case "initialize":
            return JSONRPCResponse.success(id: request.id, result: initializeResult(for: request))
        case "notifications/initialized":
            return nil
        case "tools/list":
            return JSONRPCResponse.success(id: request.id, result: MCPListToolsResult(tools: ToolRegistry.allTools()))
        case "tools/call":
            return try await callTool(request, notify: notify)
        case "ping":
            return JSONRPCResponse.success(id: request.id, result: AnyEncodable([String: String]()))
        case "shutdown":
            shouldExit = true
            return JSONRPCResponse.success(id: request.id, result: AnyEncodable([String: String]()))
        default:
            // JSON-RPC notifications carry no id; the server must not reply to them.
            if request.id == nil { return nil }
            return JSONRPCResponse.failure(
                id: request.id,
                code: RPCErrorCode.methodNotFound,
                message: "Method not found: \(request.method)"
            )
        }
    }

    private func initializeResult(for request: JSONRPCRequest) -> MCPInitializeResult {
        let requested = (request.params?.value as? [String: Any])?["protocolVersion"] as? String
        let negotiated = requested.flatMap { MCPServer.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? MCPServer.preferredProtocolVersion
        return MCPInitializeResult(
            protocolVersion: negotiated,
            capabilities: .init(tools: .init(listChanged: false)),
            serverInfo: .init(name: "parola", version: Parola.version),
            instructions: "Engine tools (transcribe, list_models, summarize) run standalone. The other tools drive a running Parola.app over a local bridge: if they report the bridge is unreachable, call parola_open_app first. The full bridge command catalog is available via parola_app_dispatch with command '_handshake'."
        )
    }

    private func callTool(
        _ request: JSONRPCRequest,
        notify: @escaping @Sendable (JSONRPCNotification) async -> Void
    ) async throws -> JSONRPCResponse {
        guard let params = request.params?.value as? [String: Any],
              let name = params["name"] as? String else {
            return JSONRPCResponse.failure(
                id: request.id,
                code: RPCErrorCode.invalidParams,
                message: "Missing tool name"
            )
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        let progress = Self.progressToken(in: params).map { ProgressSink(token: $0, notify: notify) }

        do {
            let result: MCPToolCallResult
            if let engineTool = EngineTool(rawValue: name) {
                result = try await invoke(engineTool, args: args, progress: progress)
            } else if let typedTool = TypedToolRegistry.byName[name] {
                result = try await typedTool.invoke(args: args, bridge: bridge)
            } else if name == TypedToolRegistry.appDispatch.name {
                result = try await dispatchAppCommand(args: args)
            } else if let appTool = AppTools.byName[name] {
                result = try await appTool.invoke(args: args, bridge: bridge)
            } else {
                return JSONRPCResponse.success(
                    id: request.id,
                    result: MCPToolCallResult(text: "Unknown tool: \(name)", isError: true)
                )
            }
            return JSONRPCResponse.success(id: request.id, result: result)
        } catch is CancellationError {
            // Only a real task cancellation may propagate and stop the server; a CancellationError
            // thrown inside a tool must stay contained or one tool kills the whole session.
            if Task.isCancelled { throw CancellationError() }
            return JSONRPCResponse.success(
                id: request.id,
                result: MCPToolCallResult(text: "Cancelled: \(name)", isError: true)
            )
        } catch {
            return JSONRPCResponse.success(
                id: request.id,
                result: MCPToolCallResult(text: error.localizedDescription, isError: true)
            )
        }
    }

    static func progressToken(in params: [String: Any]) -> ProgressToken? {
        guard let meta = params["_meta"] as? [String: Any] else { return nil }
        if let value = meta["progressToken"] as? Int { return .int(value) }
        // A fractional or exponent literal is a legal token and decodes to Double, not Int.
        if let value = meta["progressToken"] as? Double { return .number(value) }
        if let value = meta["progressToken"] as? String { return .string(value) }
        return nil
    }

    private func invoke(
        _ tool: EngineTool,
        args: [String: Any],
        progress: ProgressSink?
    ) async throws -> MCPToolCallResult {
        switch tool {
        case .transcribe:    return try await transcribe(args: args, progress: progress)
        case .listModels:    return listModels()
        case .listEngines:   return await listEngines()
        case .searchLibrary: return await searchLibrary(args: args)
        case .listRecent:    return await listRecent(args: args)
        case .libraryStats:  return await libraryStats()
        case .summarize:     return try await summarize(args: args)
        case .openApp:       return try await openApp(args: args)
        }
    }

    private func transcribe(args: [String: Any], progress: ProgressSink?) async throws -> MCPToolCallResult {
        let request = try TranscribeRequest(args: args)
        let duplicate = await DuplicateNotice.lookup(for: request.sourceURL, in: libraryStore)
        if let existing = duplicate.entry, request.skipDuplicates {
            return MCPToolCallResult(text: DuplicateNotice.text(for: existing, skipping: true))
        }
        let transcript = try await transcribe(
            source: FileAudioSource(url: request.sourceURL),
            options: request.options,
            progress: progress
        )
        let rendered = try request.format.render(transcript)
        var blocks = outputBlocks(for: transcript, rendered: rendered, request: request)
        if let timing = TranscribeReport.timingNote(for: transcript) {
            blocks.append(timing)
        }
        if let existing = duplicate.entry {
            blocks.append(DuplicateNotice.text(for: existing, skipping: false))
        }
        if request.save {
            blocks.append(await saveNote(
                for: transcript, sourceURL: request.sourceURL, digest: duplicate.digest
            ))
        }
        return MCPToolCallResult(texts: blocks)
    }

    /// A failed write is reported rather than thrown, for the same reason as a failed save: the
    /// transcript is finished, and dropping it costs the caller the whole run again.
    func outputBlocks(for transcript: Transcript, rendered: String, request: TranscribeRequest) -> [String] {
        let transcriptBlock = rendered.isEmpty ? TranscribeReport.noSpeechNote : rendered
        guard let outputURL = request.outputURL else { return [transcriptBlock] }
        do {
            _ = try request.writeOutput(rendered)
            return [TranscribeReport.text(
                for: transcript,
                rendered: rendered,
                format: request.format,
                outputURL: outputURL
            )]
        } catch {
            return [transcriptBlock, "Writing \(outputURL.path) failed: \(error.localizedDescription)"]
        }
    }

    /// A failed library save is reported rather than thrown: the transcription itself succeeded and
    /// the caller still wants its text back.
    func saveNote(for transcript: Transcript, sourceURL: URL, digest: String? = nil) async -> String {
        do {
            let entry = try await libraryStore.add(
                transcript: transcript, audioSource: sourceURL, sourceDigest: digest
            )
            // The search index saves on a debounce; this process can exit before it fires.
            await libraryStore.flush()
            return "Saved to the library as `\(entry.id)`."
        } catch {
            return "Saving to the library failed: \(error.localizedDescription)"
        }
    }

    private func transcribe(
        source: FileAudioSource,
        options: TranscriptionOptions,
        progress: ProgressSink?
    ) async throws -> Transcript {
        guard let progress else {
            return try await session.transcribe(source: source, options: options)
        }
        // The session owns the store and the configuration that pick the model; resolving it here could disagree.
        let plan = await session.modelPlan(for: options)
        let map = TranscribeProgressMap(
            model: plan.model,
            duration: await source.estimatedDuration(),
            downloadsModel: plan.needsDownload
        )
        let reporter = progress.reporter()
        do {
            let transcript = try await session.transcribe(
                source: source,
                options: options,
                downloadProgress: { reporter.report(map.downloading($0)) },
                progressHandler: { reporter.report(map.transcribed(seconds: $0)) },
                stageHandler: { reporter.report(map.entering($0)) }
            )
            await reporter.finish()
            return transcript
        } catch {
            await reporter.finish()
            throw error
        }
    }

    private func listModels() -> MCPToolCallResult {
        let grouped = ModelCatalog.groupedForPicker()
        let installed = Set(modelStore.catalog().filter(\.isInstalled).map(\.name))
        var lines: [String] = []
        for (category, variants) in grouped {
            lines.append("## \(category.displayName)")
            for variant in variants {
                let mark = installed.contains(variant.id) ? "x" : " "
                lines.append("- [\(mark)] `\(variant.id)` — \(variant.displayName) (\(variant.engineID))")
                lines.append("    \(variant.tagline)")
            }
        }
        return MCPToolCallResult(text: lines.joined(separator: "\n"))
    }

    private func listEngines() async -> MCPToolCallResult {
        await ParolaCoreBootstrap.registerBuiltInEngines()
        let registry = EngineRegistry.shared
        let ids = await registry.registeredEngines()
        var lines: [String] = []
        for id in ids {
            let caps = await registry.capabilities(for: id)
            lines.append("- `\(id.rawValue)` (translate=\(caps?.supportsTranslate ?? false), prompt=\(caps?.supportsInitialPrompt ?? false))")
        }
        return MCPToolCallResult(text: lines.joined(separator: "\n"))
    }

    private func searchLibrary(args: [String: Any]) async -> MCPToolCallResult {
        let query = (args["query"] as? String) ?? ""
        let limit = max(0, args["limit"] as? Int ?? 10)
        let matches = await libraryStore.search(query)
        let lines = matches.prefix(limit).map { match in
            // A title, summary or speaker hit is not spoken anywhere, so it carries no time.
            let time = match.firstHit.map { ", at \(Timecode.format($0.seconds))" } ?? ""
            return "- `\(match.entryID)` (score \(match.score)\(time)) \(match.snippet)"
        }
        return MCPToolCallResult(text: lines.joined(separator: "\n"))
    }

    private func listRecent(args: [String: Any]) async -> MCPToolCallResult {
        let limit = max(0, args["limit"] as? Int ?? 10)
        let entries = await libraryStore.list().prefix(limit)
        return MCPToolCallResult(text: entries.map { "- \($0.title)" }.joined(separator: "\n"))
    }

    private func libraryStats() async -> MCPToolCallResult {
        let stats = LibraryStatistics.compute(entries: await libraryStore.list())
        return MCPToolCallResult(text: LibraryStatsReport.text(stats))
    }

    private func summarize(args: [String: Any]) async throws -> MCPToolCallResult {
        try features.require(.ai)
        guard let path = args["path"] as? String else {
            throw MCPToolError("Missing required argument: path")
        }
        let url = URL(fileURLWithPath: path)
        let source = FileAudioSource(url: url)
        let transcript = try await session.transcribe(
            source: source,
            options: TranscriptionOptions()
        )
        let model = try await LanguageModelFactory.makeOnDevice(
            instructions: "Summarise the transcript in 3 short bullet points."
        )
        let summary = try await model.respond(to: transcript.text)
        return MCPToolCallResult(text: summary)
    }

    private func openApp(args: [String: Any]) async throws -> MCPToolCallResult {
        let timeoutMs = args["timeoutMs"] as? Int ?? 10_000
        let bundleID = args["bundleID"] as? String ?? AppLauncher.defaultBundleID
        let report = try await AppLauncher.launch(bundleID: bundleID, timeoutMs: timeoutMs)
        return MCPToolCallResult(text: report)
    }

    private func dispatchAppCommand(args: [String: Any]) async throws -> MCPToolCallResult {
        guard let command = args["command"] as? String, !command.isEmpty else {
            throw MCPToolError("parola_app_dispatch requires 'command'")
        }
        let inner = (args["args"] as? [String: Any]) ?? [:]
        let argsData = (try? JSONSerialization.data(withJSONObject: inner)) ?? Data("{}".utf8)
        let text = try await bridge.call(command, argsJSON: argsData)
        return MCPToolCallResult(text: text)
    }

}

public struct MCPToolError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
