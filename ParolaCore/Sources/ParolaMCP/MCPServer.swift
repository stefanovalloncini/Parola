import Foundation
import ParolaCore

/// JSON-RPC handler for the Parola MCP server. Owns the engine session and proxies app-bridge calls.
public actor MCPServer {
    public static let supportedProtocolVersions: Set<String> = ["2024-11-05", "2025-03-26"]
    public static let preferredProtocolVersion: String = "2024-11-05"

    private let session: TranscriptionSession
    private let modelStore: ModelStore
    private let libraryStore: LibraryStore
    private let bridge: any BridgeProtocol
    private(set) var shouldExit: Bool = false

    private var cachedToolList: [MCPTool] = ToolRegistry.allTools()
    private var cachedBridgeVersion: Int?

    public func requestExit() {
        shouldExit = true
    }

    public init(
        session: TranscriptionSession = TranscriptionSession(),
        modelStore: ModelStore = .shared,
        libraryStore: LibraryStore = .shared,
        bridge: any BridgeProtocol = BridgeClient()
    ) {
        self.session = session
        self.modelStore = modelStore
        self.libraryStore = libraryStore
        self.bridge = bridge
    }

    public func handle(_ request: JSONRPCRequest) async throws -> JSONRPCResponse? {
        switch request.method {
        case "initialize":
            return JSONRPCResponse.success(id: request.id, result: initializeResult(for: request))
        case "notifications/initialized":
            return nil
        case "tools/list":
            await refreshToolListIfNeeded()
            return JSONRPCResponse.success(id: request.id, result: MCPListToolsResult(tools: cachedToolList))
        case "tools/call":
            return try await callTool(request)
        case "shutdown":
            shouldExit = true
            return JSONRPCResponse.success(id: request.id, result: AnyEncodable([String: String]()))
        default:
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
            serverInfo: .init(name: "parola", version: Parola.version)
        )
    }

    private func callTool(_ request: JSONRPCRequest) async throws -> JSONRPCResponse {
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
        } catch let error as CancellationError {
            throw error
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
        case .openApp:       return try await openApp(args: args)
        }
    }

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
        let limit = args["limit"] as? Int ?? 10
        let matches = await libraryStore.search(query)
        let lines = matches.prefix(limit).map { match in
            "- `\(match.entryID)` (score \(match.score)) \(match.snippet)"
        }
        return MCPToolCallResult(text: lines.joined(separator: "\n"))
    }

    private func listRecent(args: [String: Any]) async -> MCPToolCallResult {
        let limit = args["limit"] as? Int ?? 10
        let entries = await libraryStore.list().prefix(limit)
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
        let model = try await LanguageModelFactory.makeOnDevice(
            instructions: "Summarise the transcript in 3 short bullet points."
        )
        let summary = try await model.respond(to: transcript.text)
        return MCPToolCallResult(text: summary)
    }

    private func openApp(args: [String: Any]) async throws -> MCPToolCallResult {
        let timeoutMs = args["timeoutMs"] as? Int ?? 10_000
        let bundleID = args["bundleID"] as? String ?? "com.parola.Parola"
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

    private func refreshToolListIfNeeded() async {
        let version = await fetchHandshakeVersion()
        guard version != cachedBridgeVersion else { return }
        cachedBridgeVersion = version
        cachedToolList = ToolRegistry.allTools()
    }

    private func fetchHandshakeVersion() async -> Int? {
        let raw = try? await bridge.call("_handshake", argsJSON: Data("{}".utf8))
        guard let raw,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["serverVersion"] as? Int
    }
}

public struct MCPToolError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
