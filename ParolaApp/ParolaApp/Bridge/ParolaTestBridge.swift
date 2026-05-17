import Foundation
import AppKit
import Network
import PDFKit
import Security
import ParolaCore

/// TCP-loopback IPC server for external tooling (e.g. parola-mcp). Line-delimited JSON,
/// `{id, cmd, args, auth}` → `{id, ok, result|error}`. Writes the port to
/// `~/Library/Caches/Parola/bridge.port` and the auth token to `bridge.token` on start.
@MainActor
final class ParolaTestBridge {
    static let serverVersion: Int = 1

    private let listener: NWListener
    private weak var model: AppModel?
    private let portFileURL: URL
    private let tokenFileURL: URL
    private let authToken: String
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var onPortReady: (@MainActor (UInt16) -> Void)?

    init(model: AppModel) throws {
        self.model = model

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
    }

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
                    FileHandle.standardError.write(
                        Data("[ParolaTestBridge] listening on 127.0.0.1:\(portString)\n".utf8)
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
        try? FileManager.default.removeItem(at: portFileURL)
        try? FileManager.default.removeItem(at: tokenFileURL)
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
                for lineData in lines {
                    let response = await handle(line: lineData)
                    var out = response
                    out.append(0x0A)
                    await send(out, on: conn, ending: isComplete && lines.last == lineData)
                }
                if isComplete {
                    if lines.isEmpty { conn.cancel() }
                    return
                }
            } catch {
                FileHandle.standardError.write(
                    Data("[ParolaTestBridge] receive error: \(error)\n".utf8)
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
                        Data("[ParolaTestBridge] send error: \(sendErr)\n".utf8)
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
        let id: String
        let cmd: String
        let args: [String: Any]
        let auth: String

        do {
            let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] ?? [:]
            id = obj["id"] as? String ?? ""
            cmd = obj["cmd"] as? String ?? ""
            args = obj["args"] as? [String: Any] ?? [:]
            auth = obj["auth"] as? String ?? ""
        } catch {
            return Self.encode([
                "id": "",
                "ok": false,
                "serverVersion": Self.serverVersion,
                "error": "invalid JSON: \(error.localizedDescription)",
            ])
        }

        guard authenticate(auth) else {
            return Self.encode(["id": id, "ok": false, "error": "auth required"])
        }

        do {
            let result = try await dispatch(cmd: cmd, args: args)
            return Self.encode([
                "id": id,
                "ok": true,
                "serverVersion": Self.serverVersion,
                "result": result,
            ])
        } catch let bridgeError as BridgeError {
            return Self.encode([
                "id": id,
                "ok": false,
                "serverVersion": Self.serverVersion,
                "error": bridgeError.message,
            ])
        } catch {
            return Self.encode([
                "id": id,
                "ok": false,
                "serverVersion": Self.serverVersion,
                "error": "\(error)",
            ])
        }
    }

    private func authenticate(_ candidate: String) -> Bool {
        let lhs = Array(authToken.utf8)
        let rhs = Array(candidate.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
    }

    private func dispatch(cmd: String, args: [String: Any]) async throws -> Any {
        guard let model else { throw BridgeError("AppModel released") }

        switch cmd {
        case "ping":
            return ["pong": true]

        case "_handshake":
            return [
                "serverVersion": Self.serverVersion,
                "appVersion": Parola.version,
                "commands": Self.knownCommands,
            ] as [String: Any]

        case "getState":
            return state(of: model)

        case "selectModel":
            let name = try requireString(args, "name")
            UserDefaults.standard.set(name, forKey: "selectedModel")
            model.objectWillChange.send()
            return ["selectedModel": name]

        case "setLanguage":
            let code = (args["code"] as? String) ?? ""
            UserDefaults.standard.set(code, forKey: "selectedLanguageRaw")
            model.objectWillChange.send()
            return ["language": code]

        case "setTheme":
            let theme = try requireString(args, "theme")
            guard ["light", "dark", "system"].contains(theme) else {
                throw BridgeError("'theme' must be one of: light, dark, system")
            }
            UserDefaults.standard.set(theme, forKey: "appTheme")
            model.objectWillChange.send()
            return ["appTheme": theme]

        case "setRoute":
            let raw = try requireString(args, "route")
            guard let route = AppModel.Route(rawValue: raw) else {
                throw BridgeError("unknown route: \(raw)")
            }
            model.route = route
            return ["route": route.rawValue]

        case "setLibraryFilter":
            let raw = (args["category"] as? String) ?? ""
            if raw.isEmpty {
                model.libraryFilter = nil
            } else if let cat = EntryCategory(rawValue: raw) {
                model.libraryFilter = cat
            } else {
                throw BridgeError("unknown category: \(raw)")
            }
            return ["libraryFilter": raw]

        case "transcribeYouTube":
            let url = try requireString(args, "url")
            model.transcribeYouTube(urlString: url)
            return ["started": true]

        case "startRecording":
            let source = (args["source"] as? String) ?? "microphone"
            let recordSource: AppModel.RecordSource = (source == "systemAudio") ? .systemAudio : .microphone
            let category = EntryCategory(rawValue: (args["category"] as? String) ?? "") ?? .transcription
            model.pendingRecordingCategory = category
            model.startRecording(source: recordSource)
            return ["started": true, "source": source, "category": category.rawValue]

        case "stopRecording":
            model.stopRecordingAndTranscribe()
            return ["stopped": true]

        case "startDictation":
            model.startDictationFromIntent()
            return ["started": true]

        case "stopDictation":
            model.stopDictationFromIntent()
            return ["stopped": true]

        case "setTranslate":
            let on = try requireBool(args, "on")
            UserDefaults.standard.set(on, forKey: "translate")
            model.objectWillChange.send()
            return ["translate": on]

        case "setUseStreaming":
            let on = try requireBool(args, "on")
            UserDefaults.standard.set(on, forKey: "useStreaming")
            model.objectWillChange.send()
            return ["useStreaming": on]

        case "toggleLiveCaptions":
            let before = model.liveCaptions?.isActive ?? false
            model.toggleLiveCaptions()
            // toggleLiveCaptions kicks off an async Task; wait briefly so callers see the flip.
            let deadline = Date().addingTimeInterval(1.0)
            while (model.liveCaptions?.isActive ?? false) == before, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return ["liveCaptionsActive": model.liveCaptions?.isActive ?? false]

        case "openYouTubeSheet":
            model.youtubeSheetOpen = true
            return ["open": true]

        case "closeYouTubeSheet":
            model.youtubeSheetOpen = false
            return ["open": false]

        case "fetchYouTubeSubs":
            let url = try requireString(args, "url")
            model.fetchYouTubeSubs(urlString: url)
            return ["started": true]

        case "dismissError":
            model.dismissError()
            return ["dismissed": true]

        case "cancel":
            let wasCancellable = model.canCancel
            model.cancelCurrentWork()
            return ["cancelled": wasCancellable]

        case "clearTranscript":
            model.transcript = nil
            if case .ready = model.phase { model.phase = .idle }
            return ["cleared": true]

        case "listEntries":
            let limit = (args["limit"] as? Int) ?? 50
            let category = args["category"] as? String
            let entries = model.libraryEntries.filter { entry in
                guard let category, !category.isEmpty else { return true }
                return entry.category.rawValue == category
            }.prefix(limit)
            return entries.map { entry in
                [
                    "id": entry.id,
                    "title": entry.title,
                    "category": entry.category.rawValue,
                    "createdAt": entry.createdAt.timeIntervalSince1970,
                ] as [String: Any]
            }

        case "loadEntry":
            let id = try requireString(args, "id")
            model.loadEntry(id)
            return ["loaded": id]

        case "deleteEntry":
            let id = try requireString(args, "id")
            model.deleteEntry(id)
            return ["deleted": id]

        case "downloadModel":
            let name = try requireString(args, "name")
            model.downloadModel(name)
            return ["started": true, "name": name]

        case "deleteModel":
            let name = try requireString(args, "name")
            model.deleteModel(name)
            return ["deleted": name]

        case "exportTranscript":
            guard model.transcript != nil else { throw BridgeError("no transcript loaded") }
            let raw = try requireString(args, "format")
            guard let format = ExportFormat(rawValue: raw) else {
                throw BridgeError("invalid format: \(raw)")
            }
            model.performExport(format)
            return ["queued": true, "format": raw]

        case "screenshot":
            let requested = (args["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let target = try resolveScreenshotPath(requested)
            return try captureMainWindow(path: target.path)

        case "listPrompts":
            let prompts = await model.promptLibrary.allPrompts
            return prompts.map { p in
                [
                    "id": p.id.uuidString,
                    "name": p.name,
                    "isBuiltIn": p.isBuiltIn,
                    "instructions": p.instructions,
                ] as [String: Any]
            }

        case "runPrompt":
            guard let identifier = (args["name"] as? String) ?? (args["id"] as? String) else {
                throw BridgeError("missing 'name' or 'id'")
            }
            let prompts = await model.promptLibrary.allPrompts
            guard let prompt = prompts.first(where: { $0.name == identifier || $0.id.uuidString == identifier }) else {
                throw BridgeError("prompt not found: \(identifier)")
            }
            guard model.transcript != nil else { throw BridgeError("no transcript loaded to run prompt on") }
            model.runPrompt(prompt)
            return ["started": true, "prompt": prompt.name]

        case "getPromptOutput":
            guard let out = model.promptOutput else { return NSNull() }
            return ["promptName": out.promptName, "text": out.text]

        case "transcribeFile":
            let path = try requireString(args, "path")
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw BridgeError("file not found: \(path)")
            }
            model.transcribe(fileURL: url, translateOverride: args["translate"] as? Bool)
            return ["started": true, "file": url.path]

        case "startBatch":
            let urls = try resolveExistingPaths(args)
            model.startBatch(urls: urls)
            return ["started": true, "count": urls.count]

        case "addBatchFiles":
            let urls = try resolveExistingPaths(args)
            model.addBatchFiles(urls)
            return ["added": urls.count]

        case "clearBatch":
            model.clearBatch()
            return ["cleared": true]

        case "selectBatchJob":
            let idStr = try requireString(args, "id")
            guard let id = UUID(uuidString: idStr) else { throw BridgeError("invalid 'id'") }
            model.selectBatchJob(id)
            return ["selected": idStr]

        case "summarizeLatestEntry":
            model.summarizeLatestEntry()
            return ["started": true]

        case "revealCacheDirectory":
            model.revealCacheDirectory()
            return ["revealed": true]

        case "getBatchJobs":
            return model.batchJobs.map { job in
                [
                    "id": job.id.uuidString,
                    "url": job.url.path,
                    "status": job.status.rawValue,
                    "progress": job.progress,
                    "error": job.error ?? "",
                    "hasTranscript": job.transcript != nil,
                ] as [String: Any]
            }

        case "getSettings":
            let d = UserDefaults.standard
            let keys = [
                "useStreaming", "wordTimestamps", "karaokeHighlight", "initialPrompt",
                "diarize", "batchExportFormats", "batchExportToSourceFolder",
                "batchExportIncludeTimestamps", "selectedModel", "selectedLanguageRaw",
                "translate", "dictationEnabled", "appTheme", "monospacedTimestamps",
                "sidebarDensity", "dictationCleanupPromptID", "dictationPerAppOverridesJSON",
                "meetingDetectorEnabled",
            ]
            var out: [String: Any] = [:]
            for key in keys {
                out[key] = d.object(forKey: key) ?? NSNull()
            }
            return out

        case "setSetting":
            let key = try requireString(args, "key")
            let value = args["value"]
            guard Self.writableSettingKeys.contains(key) else {
                throw BridgeError("setting '\(key)' is not writable through the bridge")
            }
            UserDefaults.standard.set(value, forKey: key)
            model.objectWillChange.send()
            return ["key": key, "value": value ?? NSNull()]

        case "openSettings":
            let visibleCountBefore = NSApp.windows.filter { $0.isVisible }.count
            if #available(macOS 14.0, *) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
            try? await Task.sleep(for: .milliseconds(300))
            let visibleAfter = NSApp.windows.filter { $0.isVisible }
            // Settings window sits in the 400–1300pt band; main window is wider.
            let settingsWin = visibleAfter.first(where: { $0.frame.width < 1300 && $0.frame.width > 400 })
            return [
                "opened": visibleAfter.count > visibleCountBefore || settingsWin != nil,
                "visibleCount": visibleAfter.count,
                "settingsSize": ["w": Int(settingsWin?.frame.width ?? 0), "h": Int(settingsWin?.frame.height ?? 0)],
            ]

        case "closeSettings":
            var closed = false
            let mainContent = NSApp.windows.first(where: { $0.frame.width > 1300 && $0.title == "" && !$0.isSheet })
            for win in NSApp.windows where win.isVisible && win !== mainContent && !win.isSheet {
                if win.frame.width < 1300 || win.title.contains("Settings") || win.title.contains("Preferences") {
                    win.close()
                    closed = true
                }
            }
            return ["closed": closed]

        case "listDeletedEntries":
            let limit = (args["limit"] as? Int) ?? 50
            return model.deletedEntries.prefix(limit).map { e in
                [
                    "id": e.id,
                    "title": e.title,
                    "category": e.category.rawValue,
                    "createdAt": e.createdAt.timeIntervalSince1970,
                    "deletedAt": e.deletedAt?.timeIntervalSince1970 ?? 0,
                ] as [String: Any]
            }

        case "restoreEntry":
            let id = try requireString(args, "id")
            model.restoreEntry(id)
            return ["restored": id]

        case "purgeEntry":
            let id = try requireString(args, "id")
            model.purgeEntry(id)
            return ["purged": id]

        case "search":
            let query = try requireString(args, "query")
            model.searchResults = nil
            model.search(query)
            // AppModel.search debounces 200ms before running async; poll until results land.
            let deadline = Date().addingTimeInterval(2.0)
            while model.searchResults == nil, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let results = model.searchResults ?? []
            let limit = (args["limit"] as? Int) ?? 20
            return results.prefix(limit).map { e in
                ["id": e.id, "title": e.title, "category": e.category.rawValue] as [String: Any]
            }

        case "listWindows":
            return NSApp.windows.compactMap { win -> [String: Any]? in
                guard win.isVisible else { return nil }
                return [
                    "title": win.title,
                    "frame": ["w": Int(win.frame.size.width), "h": Int(win.frame.size.height)],
                    "isKey": win.isKeyWindow,
                    "isMain": win.isMainWindow,
                ]
            }

        case "waitForPhase":
            let expected = try requireString(args, "phase")
            let timeoutMs = (args["timeoutMs"] as? Int) ?? 10_000
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
            while Date() < deadline {
                if Self.phaseName(model.phase) == expected {
                    return ["matched": true, "state": state(of: model)]
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return ["matched": false, "state": state(of: model)]

        case "getTranscript":
            guard let t = model.transcript else { return NSNull() }
            return [
                "text": t.segments.map(\.text).joined(separator: "\n"),
                "language": t.language,
                "modelName": t.modelName,
                "segmentCount": t.segments.count,
                "durationSeconds": t.durationSeconds ?? 0,
            ]

        default:
            throw BridgeError("unknown command: \(cmd)")
        }
    }

    static let writableSettingKeys: Set<String> = [
        "useStreaming", "wordTimestamps", "karaokeHighlight", "initialPrompt",
        "diarize", "batchExportFormats", "batchExportToSourceFolder",
        "batchExportIncludeTimestamps", "selectedModel", "selectedLanguageRaw",
        "translate", "dictationEnabled", "appTheme", "monospacedTimestamps",
        "sidebarDensity", "dictationCleanupPromptID", "dictationPerAppOverridesJSON",
        "meetingDetectorEnabled", "dictationModeRaw", "dictationKeyCode",
        "dictationIndicatorStyleRaw", "automationBridgeEnabled",
        "transcriptDisplayMode",
    ]

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
            throw BridgeError("screenshot 'path' must be a bare filename")
        }
        return dir.appendingPathComponent(bare)
    }

    private func captureMainWindow(path: String) throws -> [String: Any] {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && !$0.isMiniaturized && $0.frame.size.width > 200 }),
              let view = window.contentView else {
            throw BridgeError("no visible main window to capture")
        }
        // dataWithPDF flattens layer-backed SwiftUI subviews; bitmapImageRepForCachingDisplay
        // produces transparent output on this codebase.
        let pdfData = view.dataWithPDF(inside: view.bounds)
        guard let pdfDoc = PDFDocument(data: pdfData), let page = pdfDoc.page(at: 0) else {
            throw BridgeError("could not parse window PDF")
        }
        let pageRect = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        let pixelSize = NSSize(width: pageRect.width * scale, height: pageRect.height * scale)
        let image = NSImage(size: pixelSize, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            NSColor.windowBackgroundColor.setFill()
            ctx.fill(CGRect(origin: .zero, size: pixelSize))
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            throw BridgeError("failed to encode PNG")
        }
        try pngData.write(to: URL(fileURLWithPath: path))
        return [
            "path": path,
            "width": Int(pixelSize.width),
            "height": Int(pixelSize.height),
            "bytes": pngData.count,
            "windowTitle": window.title,
        ]
    }

    private func state(of model: AppModel) -> [String: Any] {
        // @AppStorage doesn't always reflect cross-context UserDefaults writes synchronously.
        let defaults = UserDefaults.standard
        let selectedModel = defaults.string(forKey: "selectedModel") ?? "openai_whisper-tiny"
        let language = defaults.string(forKey: "selectedLanguageRaw") ?? ""
        let appTheme = defaults.string(forKey: "appTheme") ?? "system"
        let useStreaming = (defaults.object(forKey: "useStreaming") as? Bool) ?? true
        let translate = defaults.bool(forKey: "translate")

        return [
            "phase": Self.phaseName(model.phase),
            "phaseDetail": Self.phaseDetail(model.phase),
            "route": model.route.rawValue,
            "libraryFilter": model.libraryFilter?.rawValue ?? "",
            "selectedModel": selectedModel,
            "language": language,
            "translate": translate,
            "useStreaming": useStreaming,
            "ytDlpAvailable": model.ytDlpAvailable,
            "appTheme": appTheme,
            "hasTranscript": model.transcript != nil,
            "transcriptSegments": model.transcript?.segments.count ?? 0,
            "availableModels": model.availableModels.map(\.name),
            "isRunningPrompt": model.isRunningPrompt,
            "youtubeSheetOpen": model.youtubeSheetOpen,
            "liveCaptionsActive": model.liveCaptions?.isActive ?? false,
            "batchJobCount": model.batchJobs.count,
        ]
    }

    private func requireString(_ args: [String: Any], _ key: String) throws -> String {
        guard let v = args[key] as? String, !v.isEmpty else { throw BridgeError("missing '\(key)'") }
        return v
    }

    private func requireBool(_ args: [String: Any], _ key: String) throws -> Bool {
        guard let v = args[key] as? Bool else { throw BridgeError("missing '\(key)'") }
        return v
    }

    private func resolveExistingPaths(_ args: [String: Any]) throws -> [URL] {
        guard let paths = args["paths"] as? [String], !paths.isEmpty else {
            throw BridgeError("missing 'paths' (array of file paths)")
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard missing.isEmpty else {
            throw BridgeError("missing files: \(missing.map(\.path).joined(separator: ", "))")
        }
        return urls
    }

    private static func phaseName(_ phase: AppModel.Phase) -> String {
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

    private static func phaseDetail(_ phase: AppModel.Phase) -> [String: Any] {
        switch phase {
        case .idle, .ready:
            return [:]
        case .downloadingModel(let name, let progress):
            return ["name": name, "progress": progress]
        case .loadingModel(let name):
            return ["name": name]
        case .transcribing(let file):
            return ["file": file.path]
        case .recording(let source):
            return ["source": source.rawValue]
        case .failed(let message):
            return ["message": message]
        }
    }

    private static func encode(_ payload: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    }

    static let knownCommands: [String] = [
        "_handshake", "ping", "getState",
        "selectModel", "setLanguage", "setTheme", "setRoute", "setLibraryFilter",
        "transcribeYouTube", "fetchYouTubeSubs",
        "startRecording", "stopRecording", "startDictation", "stopDictation",
        "setTranslate", "setUseStreaming", "toggleLiveCaptions",
        "openYouTubeSheet", "closeYouTubeSheet",
        "dismissError", "cancel", "clearTranscript",
        "listEntries", "loadEntry", "deleteEntry",
        "downloadModel", "deleteModel", "exportTranscript",
        "screenshot", "listPrompts", "runPrompt", "getPromptOutput",
        "transcribeFile",
        "startBatch", "addBatchFiles", "clearBatch", "selectBatchJob", "getBatchJobs",
        "summarizeLatestEntry", "revealCacheDirectory",
        "getSettings", "setSetting", "openSettings", "closeSettings",
        "listDeletedEntries", "restoreEntry", "purgeEntry", "search",
        "listWindows", "waitForPhase", "getTranscript",
    ]
}

private struct BridgeError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
