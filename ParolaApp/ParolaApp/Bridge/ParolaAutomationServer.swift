import Foundation
import AppKit
import Network
import ScreenCaptureKit
import Security
import ParolaCore

/// TCP-loopback IPC server for external tooling (e.g. parola-mcp). Line-delimited JSON,
/// `{id, cmd, args, auth}` → `AutomationResponse`. Writes the port to
/// `~/Library/Caches/Parola/bridge.port` and the auth token to `bridge.token` on start.
@MainActor
final class ParolaAutomationServer {
    static let serverVersion: Int = 2

    private let listener: NWListener
    private weak var model: AppModel?
    private let portFileURL: URL
    private let tokenFileURL: URL
    private let authToken: String
    private let discovery: BridgeDiscovery
    private let startedAt: Date
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var onPortReady: (@MainActor (UInt16) -> Void)?

    private var commands: [String: AutomationCommand] = [:]
    private var revision: Int = 0
    private let auditLog: AutomationAuditLog?
    let revisionLog: RevisionLog

    init(model: AppModel, auditLog: AutomationAuditLog? = nil, revisionLog: RevisionLog? = nil) throws {
        self.model = model
        self.auditLog = auditLog
        self.revisionLog = revisionLog ?? RevisionLog()

        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params)

        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = caches.appendingPathComponent("Parola", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.portFileURL = dir.appendingPathComponent("bridge.port")
        self.tokenFileURL = dir.appendingPathComponent("bridge.token")
        self.authToken = Self.generateToken()
        self.discovery = BridgeDiscovery(cacheDir: dir)
        self.startedAt = Date()

        self.commands = Self.buildCatalog(server: self)
    }

    private static func buildCatalog(server: ParolaAutomationServer) -> [String: AutomationCommand] {
        let lists: [[AutomationCommand]] = [
            server.coreCommands(),
            server.modelCommands(),
            server.transcriptCommands(),
            server.libraryCommands(),
            server.batchCommands(),
            server.recordingCommands(),
            server.dictationCommands(),
            server.promptCommands(),
            server.settingsCommands(),
            server.windowCommands(),
            server.waitCommands(),
            server.lifecycleCommands(),
            server.revisionLogCommands(),
            server.simulationCommands(),
            server.mockCommands(),
            server.accessibilityCommands(),
        ]
        var out: [String: AutomationCommand] = [:]
        for list in lists {
            for cmd in list { out[cmd.name] = cmd }
        }
        return out
    }

    func commandNames() -> [String] { commands.keys.sorted() }

    var isTestMode: Bool { model?.mode == .test }

    func capabilities() -> [String] {
        [
            "envelope.v2",
            "errorCodes",
            "perInstanceCatalog",
        ]
    }

    func currentRevision() -> Int { revision }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func start(onPortReady: (@MainActor (UInt16) -> Void)? = nil) {
        self.onPortReady = onPortReady
        listener.stateUpdateHandler = { state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .ready = state, let port = self.listener.port {
                    let portString = "\(port.rawValue)"
                    try? portString.write(to: self.portFileURL, atomically: true, encoding: .utf8)
                    try? self.authToken.write(to: self.tokenFileURL, atomically: true, encoding: .utf8)
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: self.tokenFileURL.path
                    )
                    try? self.discovery.write(
                        port: port.rawValue,
                        token: self.authToken,
                        pid: Int(ProcessInfo.processInfo.processIdentifier),
                        startedAt: self.startedAt,
                        serverVersion: Self.serverVersion
                    )
                    FileHandle.standardError.write(
                        Data("[ParolaAutomationServer] listening on 127.0.0.1:\(portString)\n".utf8)
                    )
                    self.onPortReady?(port.rawValue)
                }
            }
        }
        listener.newConnectionHandler = { conn in
            Task { @MainActor [weak self] in
                self?.accept(conn)
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
        for conn in connections.values { conn.cancel() }
        connections.removeAll()
        for task in connectionTasks.values { task.cancel() }
        connectionTasks.removeAll()
        if let written = try? String(contentsOf: tokenFileURL, encoding: .utf8), written == authToken {
            try? FileManager.default.removeItem(at: portFileURL)
            try? FileManager.default.removeItem(at: tokenFileURL)
            discovery.remove()
        }
    }

    private func accept(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        connections[key] = conn
        conn.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    self?.connectionTasks.removeValue(forKey: key)?.cancel()
                    self?.connections.removeValue(forKey: key)
                }
            default: break
            }
        }
        conn.start(queue: .main)
        connectionTasks[key] = Task { @MainActor [weak self] in
            await self?.runConnection(conn)
        }
    }

    private func runConnection(_ conn: NWConnection) async {
        var buffer = Data()
        while !Task.isCancelled {
            do {
                let (data, isComplete) = try await receive(from: conn)
                if let data { buffer.append(data) }
                let lines = Self.consumeLines(buffer: &buffer)
                for (index, lineData) in lines.enumerated() {
                    let response = await handle(line: lineData)
                    var out = response
                    out.append(0x0A)
                    await send(out, on: conn, ending: isComplete && index == lines.count - 1)
                }
                if isComplete {
                    if lines.isEmpty { conn.cancel() }
                    return
                }
            } catch {
                FileHandle.standardError.write(
                    Data("[ParolaAutomationServer] receive error: \(error)\n".utf8)
                )
                conn.cancel()
                return
            }
        }
    }

    private func receive(from conn: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: (data, isComplete))
                }
            }
        }
    }

    private func send(_ data: Data, on conn: NWConnection, ending: Bool) async {
        await withCheckedContinuation { cont in
            conn.send(content: data, isComplete: ending, completion: .contentProcessed { sendErr in
                if let sendErr {
                    FileHandle.standardError.write(
                        Data("[ParolaAutomationServer] send error: \(sendErr)\n".utf8)
                    )
                }
                if ending {
                    conn.cancel()
                }
                cont.resume()
            })
        }
    }

    private static func consumeLines(buffer: inout Data) -> [Data] {
        var out: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if !lineData.isEmpty { out.append(lineData) }
        }
        return out
    }

    private func handle(line: Data) async -> Data {
        let start = ContinuousClock.now

        let id: String
        let cmd: String
        let rawArgs: [String: Any]
        let auth: String

        do {
            let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] ?? [:]
            id = obj["id"] as? String ?? ""
            cmd = obj["cmd"] as? String ?? ""
            rawArgs = obj["args"] as? [String: Any] ?? [:]
            auth = obj["auth"] as? String ?? ""
        } catch {
            return AutomationResponseEncoder.encode(.failure(
                id: "",
                command: "",
                error: .internal("invalid JSON: \(error.localizedDescription)"),
                serverVersion: Self.serverVersion,
                elapsedMs: Self.elapsedMs(since: start)
            ))
        }

        guard authenticate(auth) else {
            return AutomationResponseEncoder.encode(.failure(
                id: id,
                command: cmd,
                error: .permission("auth required"),
                serverVersion: Self.serverVersion,
                elapsedMs: Self.elapsedMs(since: start)
            ))
        }

        guard let model else {
            return AutomationResponseEncoder.encode(.failure(
                id: id,
                command: cmd,
                error: .appDead("AppModel released"),
                serverVersion: Self.serverVersion,
                elapsedMs: Self.elapsedMs(since: start)
            ))
        }

        guard let command = commands[cmd] else {
            let response = AutomationResponse.failure(
                id: id, command: cmd,
                error: .unknownCommand(cmd),
                serverVersion: Self.serverVersion,
                elapsedMs: Self.elapsedMs(since: start)
            )
            await auditLog?.record(id: id, command: cmd, args: AutomationArgs(jsonObject: rawArgs), ok: false, elapsedMs: response.elapsedMs, errorCode: response.error?.code)
            return AutomationResponseEncoder.encode(response)
        }

        let parsedArgs = AutomationArgs(jsonObject: rawArgs)
        let context = AutomationContext(model: model, server: self)

        do {
            let validatedArgs = try command.validate(parsedArgs)
            let result = try await command.handler(validatedArgs, context)
            if command.kind == .mutating {
                revision &+= 1
                let stateSnapshot = snapshotState()
                let entry = RevisionEntry(
                    revision: revision,
                    timestamp: Date(),
                    cause: cmd,
                    snapshotHash: RevisionLog.hash(stateSnapshot)
                )
                await revisionLog.append(entry)
            }
            let response = AutomationResponse.success(
                id: id, command: cmd,
                result: result,
                serverVersion: Self.serverVersion,
                elapsedMs: Self.elapsedMs(since: start)
            )
            await auditLog?.record(id: id, command: cmd, args: validatedArgs, ok: true, elapsedMs: response.elapsedMs)
            return AutomationResponseEncoder.encode(response)
        } catch let err as AutomationError {
            let response = AutomationResponse.failure(
                id: id, command: cmd,
                error: err,
                serverVersion: Self.serverVersion,
                elapsedMs: Self.elapsedMs(since: start)
            )
            await auditLog?.record(id: id, command: cmd, args: parsedArgs, ok: false, elapsedMs: response.elapsedMs, errorCode: err.code)
            return AutomationResponseEncoder.encode(response)
        } catch {
            let mapped: AutomationError = .internal("\(error)")
            let response = AutomationResponse.failure(
                id: id, command: cmd,
                error: mapped,
                serverVersion: Self.serverVersion,
                elapsedMs: Self.elapsedMs(since: start)
            )
            await auditLog?.record(id: id, command: cmd, args: parsedArgs, ok: false, elapsedMs: response.elapsedMs, errorCode: mapped.code)
            return AutomationResponseEncoder.encode(response)
        }
    }

    private static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let dur = ContinuousClock.now - start
        let components = dur.components
        return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }

    private func authenticate(_ candidate: String) -> Bool {
        let lhs = Array(authToken.utf8)
        let rhs = Array(candidate.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
    }

    static let writableSettingKeys: Set<String> = [
        "useStreaming", "wordTimestamps", "karaokeHighlight", "initialPrompt",
        "diarize", "batchExportFormats", "batchExportToSourceFolder",
        "batchExportIncludeTimestamps", "selectedModel", "selectedLanguageRaw",
        "translate", "dictationEnabled", "appTheme", "monospacedTimestamps",
        "sidebarDensity", "dictationCleanupPromptID", "dictationPerAppOverridesJSON",
        "meetingDetectorEnabled", "dictationModeRaw", "dictationKeyCode",
        "dictationIndicatorStyleRaw", "automationBridgeEnabled",
        "transcriptDisplayMode", "autoTitleEntries",
    ]

    func runScreenshot(requestedFileName: String?) async throws -> AutomationValue {
        let target = try resolveScreenshotPath(requestedFileName)
        return try await captureMainWindow(path: target.path)
    }

    private func resolveScreenshotPath(_ requested: String?) throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = caches.appendingPathComponent("Parola/Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let requested else {
            let name = "screenshot-\(Int(Date().timeIntervalSince1970)).png"
            return dir.appendingPathComponent(name)
        }
        let bare = (requested as NSString).lastPathComponent
        guard !bare.isEmpty, !bare.contains("/"), !bare.contains("..") else {
            throw AutomationError.invalidArgs(field: "path", reason: "must be a bare filename")
        }
        return dir.appendingPathComponent(bare)
    }

    private func captureMainWindow(path: String) async throws -> AutomationValue {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && !$0.isMiniaturized && $0.frame.size.width > 200 }) else {
            throw AutomationError.precondition("no visible main window to capture")
        }
        do {
            return try await captureViaScreenCaptureKit(window: window, path: path)
        } catch {
            // SwiftUI content is GPU/IOSurface-backed, so an in-app CALayer/cacheDisplay
            // render comes back blank — the only faithful capture goes through the window
            // server, which needs Screen Recording. Surface the window number so a process
            // that already holds the grant can capture it instead of failing opaquely.
            throw AutomationError.permission(
                "screenshot needs Screen Recording permission (\(error.localizedDescription)). "
                + "Capture window \(window.windowNumber) from a permitted process — "
                + "`screencapture -o -x -l\(window.windowNumber) <path>` — or grant Parola Screen Recording in System Settings."
            )
        }
    }

    private func captureViaScreenCaptureKit(window: NSWindow, path: String) async throws -> AutomationValue {
        let windowID = CGWindowID(window.windowNumber)
        let windowTitle = window.title
        let scale = window.backingScaleFactor

        let content = try await SCShareableContent.current
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw AutomationError.permission("window \(windowID) not visible to ScreenCaptureKit — Screen Recording permission may be missing")
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = Int(scWindow.frame.width * scale)
        config.height = Int(scWindow.frame.height * scale)
        config.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: pixelWidth, height: pixelHeight)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw AutomationError.internal("failed to encode PNG")
        }
        try pngData.write(to: URL(fileURLWithPath: path))
        return .object([
            "path": .string(path),
            "width": .int(pixelWidth),
            "height": .int(pixelHeight),
            "bytes": .int(pngData.count),
            "windowTitle": .string(windowTitle),
            "windowNumber": .int(window.windowNumber),
            "method": .string("screenCaptureKit"),
        ])
    }

    func snapshotState() -> AutomationValue {
        guard let model else { return .null }
        let defaults = model.defaults
        let selectedModel = defaults.string(forKey: "selectedModel") ?? "openai_whisper-tiny"
        let language = defaults.string(forKey: "selectedLanguageRaw") ?? ""
        let appTheme = defaults.string(forKey: "appTheme") ?? "system"
        let themePreset = defaults.string(forKey: "appAccentColor") ?? "terracotta"
        let themeIsCustom = defaults.bool(forKey: "themeIsCustom")
        let useStreaming = (defaults.object(forKey: "useStreaming") as? Bool) ?? true
        let translate = defaults.bool(forKey: "translate")

        return .object([
            "phase": .string(Self.phaseName(model.phase)),
            "phaseDetail": Self.phaseDetail(model.phase),
            "route": .string(model.route.rawValue),
            "settingsPane": .string(model.settingsPane),
            "libraryFilter": .string(model.libraryFilter?.rawValue ?? ""),
            "selectedModel": .string(selectedModel),
            "language": .string(language),
            "translate": .bool(translate),
            "useStreaming": .bool(useStreaming),
            "ytDlpAvailable": .bool(model.ytDlpAvailable),
            "appTheme": .string(appTheme),
            "themePreset": .string(themePreset),
            "themeIsCustom": .bool(themeIsCustom),
            "hasTranscript": .bool(model.transcript != nil),
            "transcriptSegments": .int(model.transcript?.segments.count ?? 0),
            "availableModels": .array(model.availableModels.map { .string($0.name) }),
            "isRunningPrompt": .bool(model.isRunningPrompt),
            "youtubeSheetOpen": .bool(model.youtubeSheetOpen),
            "liveCaptionsActive": .bool(model.liveCaptions?.isActive ?? false),
            "batchJobCount": .int(model.batchJobs.count),
            "meetingDetectedApp": model.meetingDetectedApp.map { .string($0) } ?? .null,
        ])
    }

    static func phaseName(_ phase: AppModel.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .downloadingModel: return "downloadingModel"
        case .loadingModel: return "loadingModel"
        case .transcribing: return "transcribing"
        case .recording: return "recording"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }

    static func phaseDetail(_ phase: AppModel.Phase) -> AutomationValue {
        switch phase {
        case .idle, .ready:
            return .object([:])
        case .downloadingModel(let name, let progress):
            return .object(["name": .string(name), "progress": .double(progress)])
        case .loadingModel(let name):
            return .object(["name": .string(name)])
        case .transcribing(let file):
            return .object(["file": .string(file.path)])
        case .recording(let source):
            return .object(["source": .string(source.rawValue)])
        case .failed(let message):
            return .object(["message": .string(message)])
        }
    }
}
