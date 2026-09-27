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
            server.exportCommands(),
            server.deliveryCommands(),
            server.aiCommands(),
            server.peopleCommands(),
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
            server.diagnosticsCommands(),
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
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
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
                    ParolaLog.notice(.appBridge, "bridge listening on port \(Int(port.rawValue))")
                    self.onPortReady?(port.rawValue)
                }
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in
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
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in
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
                ParolaLog.error(.appBridge, "bridge receive failed", [.error: .error(error)])
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
                    ParolaLog.error(.appBridge, "bridge send failed", [.error: .error(sendErr)])
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

    func handle(line: Data) async -> Data {
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
            ParolaLog.notice(.appBridge, "bridge rejected a command with a bad token")
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
            ParolaLog.error(.appBridge, "bridge command threw an unmapped error", [.error: .error(error)])
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
        "diarize", "selectedModel", "selectedLanguageRaw",
        "translate", "dictationEnabled", "appTheme", "monospacedTimestamps",
        "sidebarDensity", "dictationCleanupPromptID", "dictationPerAppOverridesJSON",
        "meetingDetectorEnabled", "dictationModeRaw", "dictationKeyCode",
        "dictationIndicatorStyleRaw", "automationBridgeEnabled",
        "transcriptDisplayMode", "generateCardMetadata", "showAITitles", "showAISummaries",
        "customTitlePrompt", "customSummaryPrompt", "appAccentColor",
        "inspectorMode", "introductionComplete", "autostartSummary",
        "translationSideBySide", "remoteAIAcknowledged", "showMostUsedPeople",
        "openEntriesInNewWindow", "playSoundWhenFinished", "appVisibilityMode",
        "duplicateImportPolicy",
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

    static func mainAutomationWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.isVisible && $0.contentView != nil && !$0.isMiniaturized && $0.frame.size.width > 200
        }
    }

    private func captureMainWindow(path: String) async throws -> AutomationValue {
        guard let window = Self.mainAutomationWindow() else {
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
        let selectedModel = defaults.string(forKey: "selectedModel") ?? ModelCatalog.defaultModelID()
        let language = defaults.string(forKey: "selectedLanguageRaw") ?? ""
        let appTheme = defaults.string(forKey: "appTheme") ?? "system"
        let themePreset = defaults.string(forKey: "appAccentColor") ?? ThemePreset.defaultPreset.rawValue
        let themeIsCustom = defaults.bool(forKey: "themeIsCustom")
        let useStreaming = (defaults.object(forKey: "useStreaming") as? Bool) ?? true
        let translate = defaults.bool(forKey: "translate")

        return .object([
            "phase": .string(Self.phaseName(model.phase)),
            "phaseDetail": Self.phaseDetail(model.phase, progress: TranscribeProgress(model: model)),
            "route": .string(model.route.rawValue),
            "settingsPane": .string(model.settingsPane),
            "libraryFilter": .string(model.libraryFilter?.rawValue ?? ""),
            "libraryBrowsingAll": .bool(model.libraryBrowsingAll),
            "libraryOrigin": .string(model.transcriptOrigin?.bridgeName ?? ""),
            "selectedModel": .string(selectedModel),
            "language": .string(language),
            "translate": .bool(translate),
            "useStreaming": .bool(useStreaming),
            "ytDlpAvailable": .bool(model.ytDlpAvailable),
            "ytDlpVersion": .string(model.ytDlpVersion?.text ?? ""),
            "ytDlpStale": .bool(model.ytDlpIsStale),
            "ytDlpUpdating": .bool(model.ytDlpUpdating),
            "appTheme": .string(appTheme),
            "themePreset": .string(themePreset),
            "themeIsCustom": .bool(themeIsCustom),
            "hasTranscript": .bool(model.transcript != nil),
            "transcriptSegments": .int(model.transcript?.segments.count ?? 0),
            "availableModels": .array(AppModel.selectableModelNames(model.availableModels).map { .string($0) }),
            "isRunningPrompt": .bool(model.isRunningPrompt),
            "youtubeSheetOpen": .bool(model.youtubeSheetOpen),
            "liveCaptionsActive": .bool(model.liveCaptions?.isActive ?? false),
            "batchJobCount": .int(model.batchJobs.count),
            "dropPayload": .string(model.dropDragPayload?.name ?? ""),
            "dropPayloadCount": .int(model.dropDragPayload?.count ?? 0),
            "dropHighlight": .string(model.dropHighlight?.rawValue ?? ""),
            "dropZones": .string(model.dropZonePlan.name),
            "pendingLargeDropCount": .int(model.pendingLargeDrop?.count ?? 0),
            "meetingDetectedApp": model.meetingDetectedApp.map { .string($0) } ?? .null,
            "introduction": Self.introductionState(model.introduction, currentModel: model.selectedModel),
            "favoriteSegments": .array(model.favoriteSegmentIDs.sorted().map { .int($0) }),
            "favoritesOnly": .bool(model.favoritesOnly),
            "transcriptPaneMode": .string(model.transcriptPaneMode.rawValue),
            "summaryOptions": Self.encode(model.summaryOptions),
            "autostartSummary": .bool(model.autostartSummary),
            "exportPresets": Self.encode(model.exportPresets),
            "exportSpec": model.exportSheetOpen ? Self.encode(model.exportSheetSpec) : .null,
            "translation": Self.translationState(model),
            "translationSideBySide": .bool(model.translationSideBySide),
            "destinations": Self.destinationsState(model),
            "aiServices": Self.aiServicesState(model),
            "languageModelSelection": Self.encode(model.languageModelSelection),
            "remoteAIAcknowledged": .bool(model.remoteAIAcknowledged),
            "people": Self.peopleState(model),
            "speakerAssignments": Self.speakerAssignmentsState(model),
            "personFilter": model.personFilter.map { .string($0.uuidString) } ?? .null,
            "showMostUsedPeople": .bool(model.showMostUsedPeople),
            "openEntriesInNewWindow": .bool(model.openEntriesInNewWindow),
            "openEntryWindows": .array(model.openEntryWindowIDs.map { .string($0) }),
            "retranscribing": .bool(model.retranscribeRequest != nil),
            "appVisibilityMode": .string(model.appVisibilityMode.rawValue),
            "playSoundWhenFinished": .bool(model.playSoundWhenFinished),
        ])
    }

    static func translationState(_ model: AppModel) -> AutomationValue {
        if let run = model.translationCoordinator.runInProgress {
            return .object([
                "targetLanguage": .string(run.targetLanguage),
                "segmentCount": .int(run.segmentCount),
                "inProgress": .bool(true),
                "provider": .string(run.provider),
            ])
        }
        guard let translation = model.transcript?.translation else { return .null }
        return .object([
            "targetLanguage": .string(translation.targetLanguage),
            "segmentCount": .int(translation.segments.count),
            "inProgress": .bool(false),
            "provider": .string(translation.provider),
        ])
    }

    /// Round-trips a Codable value through JSON so it can travel as an `AutomationValue`.
    static func encode<T: Encodable>(_ value: T) -> AutomationValue {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return .null
        }
        return AutomationValue(object)
    }

    static func introductionState(_ introduction: IntroductionController, currentModel: String) -> AutomationValue {
        .object([
            "visible": .bool(introduction.isPresented),
            "step": .string(introduction.step.rawValue),
            "steps": .array(introduction.steps.map { .string($0.rawValue) }),
            "engine": introduction.ringedEngineID(current: currentModel).map { .string($0) } ?? .null,
            "engineChoices": .array(introduction.engineChoices.map { .string($0) }),
        ])
    }

    static func phaseName(_ phase: AppModel.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .downloadingModel: return "downloadingModel"
        case .loadingModel: return "loadingModel"
        case .fetchingLink: return "fetchingLink"
        case .transcribing: return "transcribing"
        case .recording: return "recording"
        case .exporting: return "exporting"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }

    static func phaseDetail(
        _ phase: AppModel.Phase,
        progress: TranscribeProgress = TranscribeProgress()
    ) -> AutomationValue {
        switch phase {
        case .idle, .ready:
            return .object([:])
        case .downloadingModel(let name, let progress):
            return .object(["name": .string(name), "progress": .double(progress)])
        case .loadingModel(let name):
            return .object(["name": .string(name)])
        case .fetchingLink(let title, let progress):
            return .object([
                "title": title.map { .string($0) } ?? .null,
                "progress": progress.map { .double($0) } ?? .null,
            ])
        case .transcribing(let file):
            return .object([
                "file": .string(file.path),
                "progress": progress.fraction.map { .double($0) } ?? .null,
                "stage": progress.stage.map { .string(Self.stageName($0)) } ?? .null,
                "hasPartialText": .bool(progress.hasPartialText),
            ])
        case .recording(let source):
            return .object(["source": .string(source.rawValue)])
        case .exporting(let progress):
            return .object(["progress": .double(progress)])
        case .failed(let message):
            return .object(["message": .string(message)])
        }
    }

    static func stageName(_ stage: TranscribeStage) -> String {
        switch stage {
        case .preparingAudio: return "preparingAudio"
        case .transcribing: return "transcribing"
        }
    }
}

/// What the transcribing phase reports beyond the file: the model tracks these three for the
/// progress pane, and an agent driving the bridge needs them to tell a slow run from a wedged one.
struct TranscribeProgress {
    let fraction: Double?
    let stage: TranscribeStage?
    let hasPartialText: Bool

    init(fraction: Double? = nil, stage: TranscribeStage? = nil, hasPartialText: Bool = false) {
        self.fraction = fraction
        self.stage = stage
        self.hasPartialText = hasPartialText
    }

    @MainActor
    init(model: AppModel) {
        self.init(
            fraction: model.fileTranscribeFraction,
            stage: model.fileTranscribeStage,
            hasPartialText: !model.filePartialText.isEmpty
        )
    }
}
