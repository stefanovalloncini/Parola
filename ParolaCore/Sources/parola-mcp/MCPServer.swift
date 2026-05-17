import Foundation
import ParolaCore
import ParolaMCP

actor MCPServer {
    private let session: TranscriptionSession
    private let modelStore: ModelStore
    private let libraryStore: LibraryStore?
    private let bridge: any BridgeProtocol

    init(
        session: TranscriptionSession = TranscriptionSession(),
        modelStore: ModelStore = .shared,
        libraryStore: LibraryStore? = nil,
        bridge: any BridgeProtocol = BridgeClient()
    ) {
        self.session = session
        self.modelStore = modelStore
        self.libraryStore = libraryStore
        self.bridge = bridge
    }

    func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse? {
        switch request.method {
        case "initialize":
            return JSONRPCResponse.success(id: request.id, result: initializeResult())
        case "notifications/initialized":
            return nil
        case "tools/list":
            return JSONRPCResponse.success(id: request.id, result: MCPListToolsResult(tools: ToolRegistry.allTools()))
        case "tools/call":
            return await callTool(request)
        case "shutdown":
            return JSONRPCResponse.success(id: request.id, result: AnyEncodable([String: String]()))
        default:
            return JSONRPCResponse.failure(
                id: request.id,
                code: RPCErrorCode.methodNotFound,
                message: "Method not found: \(request.method)"
            )
        }
    }

    private func initializeResult() -> MCPInitializeResult {
        MCPInitializeResult(
            protocolVersion: "2024-11-05",
            capabilities: .init(tools: .init(listChanged: false)),
            serverInfo: .init(name: "parola", version: Parola.version)
        )
    }

    private func callTool(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        guard let params = request.params?.value as? [String: Any],
              let name = params["name"] as? String else {
            return JSONRPCResponse.failure(
                id: request.id,
                code: RPCErrorCode.invalidParams,
                message: "Missing tool name"
            )
        }
        let args = params["arguments"] as? [String: Any] ?? [:]

        do {
            let result: MCPToolCallResult
            if let engineTool = EngineTool(rawValue: name) {
                result = try await invoke(engineTool, args: args)
            } else if let appTool = AppTools.byName[name] {
                result = try await appTool.invoke(args: args, bridge: bridge)
            } else {
                return JSONRPCResponse.failure(
                    id: request.id,
                    code: RPCErrorCode.invalidParams,
                    message: "Unknown tool: \(name)"
                )
            }
            return JSONRPCResponse.success(id: request.id, result: result)
        } catch {
            return JSONRPCResponse.success(
                id: request.id,
                result: MCPToolCallResult(text: error.localizedDescription, isError: true)
            )
        }
    }

    private func invoke(_ tool: EngineTool, args: [String: Any]) async throws -> MCPToolCallResult {
        switch tool {
        case .transcribe:    return try await transcribe(args: args)
        case .listModels:    return listModels()
        case .listEngines:   return await listEngines()
        case .searchLibrary: return await searchLibrary(args: args)
        case .listRecent:    return await listRecent(args: args)
        case .summarize:     return try await summarize(args: args)
        }
    }

    // MARK: - Engine tool implementations

    private func transcribe(args: [String: Any]) async throws -> MCPToolCallResult {
        guard let path = args["path"] as? String, !path.isEmpty else {
            throw MCPToolError("Missing required argument: path")
        }
        let url = URL(fileURLWithPath: path)
        let model = args["model"] as? String
        let language = args["language"] as? String
        let format = args["format"] as? String ?? "txt"
        let source = FileAudioSource(url: url)
        let transcript = try await session.transcribe(
            source: source,
            options: TranscriptionOptions(model: model, language: language)
        )
        let text: String
        switch format.lowercased() {
        case "json":
            let data = try JsonExporter().render(transcript)
            text = String(decoding: data, as: UTF8.self)
        case "srt":
            let data = try SrtExporter().render(transcript)
            text = String(decoding: data, as: UTF8.self)
        case "vtt":
            let data = try VttExporter().render(transcript)
            text = String(decoding: data, as: UTF8.self)
        case "md":
            let data = try MarkdownExporter().render(transcript)
            text = String(decoding: data, as: UTF8.self)
        default:
            text = transcript.text
        }
        return MCPToolCallResult(text: text)
    }

    private func listModels() -> MCPToolCallResult {
        let grouped = ModelCatalog.groupedForPicker()
        let installed = Set(modelStore.catalog().filter(\.isInstalled).map(\.name))
        var lines: [String] = []
        for (category, variants) in grouped {
            lines.append("## \(category.displayName)")
            for variant in variants {
                let mark = installed.contains(variant.id) ? "✓" : " "
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
        guard let store = libraryStore else {
            return MCPToolCallResult(text: "Library not available in this context.", isError: true)
        }
        let query = (args["query"] as? String) ?? ""
        let limit = args["limit"] as? Int ?? 10
        let matches = await store.search(query)
        let lines = matches.prefix(limit).map { match in
            "- `\(match.entryID)` (score \(match.score)) \(match.snippet)"
        }
        return MCPToolCallResult(text: lines.joined(separator: "\n"))
    }

    private func listRecent(args: [String: Any]) async -> MCPToolCallResult {
        guard let store = libraryStore else {
            return MCPToolCallResult(text: "Library not available.", isError: true)
        }
        let limit = args["limit"] as? Int ?? 10
        let entries = await store.list().prefix(limit)
        return MCPToolCallResult(text: entries.map { "- \($0.title)" }.joined(separator: "\n"))
    }

    private func summarize(args: [String: Any]) async throws -> MCPToolCallResult {
        guard let path = args["path"] as? String else {
            throw MCPToolError("Missing required argument: path")
        }
        let url = URL(fileURLWithPath: path)
        let source = FileAudioSource(url: url)
        let transcript = try await session.transcribe(
            source: source,
            options: TranscriptionOptions()
        )
        let model = try LanguageModelFactory.makeOnDevice(
            instructions: "Summarise the transcript in 3 short bullet points."
        )
        let summary = try await model.respond(to: transcript.text)
        return MCPToolCallResult(text: summary)
    }
}

struct MCPToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
