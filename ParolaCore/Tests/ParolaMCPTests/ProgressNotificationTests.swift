import AVFoundation
import Foundation
import ParolaCore
import Testing
import os
@testable import ParolaMCP

@Suite("MCP progress notifications")
struct ProgressNotificationTests {

    // MARK: - Token extraction

    @Test("an int progressToken survives decoding and keeps its type")
    func intTokenRoundTrips() throws {
        let params = try callParams(meta: #"{"progressToken":7}"#)
        #expect(MCPServer.progressToken(in: params) == .int(7))
    }

    @Test("a string progressToken survives decoding and keeps its type")
    func stringTokenRoundTrips() throws {
        let params = try callParams(meta: #"{"progressToken":"tok-1"}"#)
        #expect(MCPServer.progressToken(in: params) == .string("tok-1"))
    }

    @Test("a fractional progressToken is kept, not dropped for being a non-integer")
    func fractionalTokenRoundTrips() throws {
        let params = try callParams(meta: #"{"progressToken":4.5}"#)
        #expect(MCPServer.progressToken(in: params) == .number(4.5))
    }

    @Test("a call with no usable token yields nil")
    func missingTokenYieldsNil() throws {
        #expect(MCPServer.progressToken(in: try callParams(meta: nil)) == nil)
        #expect(MCPServer.progressToken(in: try callParams(meta: "{}")) == nil)
        #expect(MCPServer.progressToken(in: try callParams(meta: #"{"progressToken":true}"#)) == nil)
    }

    // MARK: - Notification shape

    @Test("a progress notification carries no id and echoes an int token")
    func notificationShapeWithIntToken() throws {
        let json = try object(JSONRPCNotification.progress(MCPProgressParams(
            progressToken: .int(7),
            progress: 42,
            total: 100,
            message: "Transcribing"
        )))
        #expect(json["jsonrpc"] as? String == "2.0")
        #expect(json["method"] as? String == "notifications/progress")
        #expect(json["id"] == nil)
        let params = try #require(json["params"] as? [String: Any])
        #expect(params["progressToken"] as? Int == 7)
        #expect(params["progress"] as? Double == 42)
        #expect(params["total"] as? Double == 100)
        #expect(params["message"] as? String == "Transcribing")
    }

    @Test("a string token stays a string and absent fields are omitted")
    func notificationShapeWithStringToken() throws {
        let json = try object(JSONRPCNotification.progress(MCPProgressParams(
            progressToken: .string("tok-1"),
            progress: 3
        )))
        let params = try #require(json["params"] as? [String: Any])
        #expect(params["progressToken"] as? String == "tok-1")
        #expect(params["total"] == nil)
        #expect(params["message"] == nil)
    }

    // MARK: - Throttling

    @Test("a sample below the next whole percent is dropped")
    func throttleNeedsAWholePercent() {
        var throttle = ProgressThrottle()
        #expect(throttle.admit(ProgressSample(percent: 10, message: "a"), at: 0)?.percent == 10)
        #expect(throttle.admit(ProgressSample(percent: 10, message: "a"), at: 5) == nil)
        #expect(throttle.admit(ProgressSample(percent: 11, message: "a"), at: 5)?.percent == 11)
    }

    @Test("samples closer than the minimum interval are held back")
    func throttleCapsTheRate() {
        var throttle = ProgressThrottle()
        #expect(throttle.admit(ProgressSample(percent: 1, message: "a"), at: 0)?.percent == 1)
        #expect(throttle.admit(ProgressSample(percent: 2, message: "a"), at: 0.05) == nil)
        #expect(throttle.admit(ProgressSample(percent: 3, message: "a"), at: 0.2)?.percent == 3)
    }

    @Test("a burst inside one window reports its newest sample, not its oldest")
    func throttleKeepsTheNewestOfABurst() {
        var throttle = ProgressThrottle()
        #expect(throttle.admit(ProgressSample(percent: 5, message: "a"), at: 0)?.percent == 5)
        for percent in 6...97 {
            #expect(throttle.admit(ProgressSample(percent: percent, message: "a"), at: 0.01) == nil)
        }
        #expect(throttle.admit(ProgressSample(percent: 98, message: "a"), at: 0.5)?.percent == 98)
    }

    @Test("the sample held when the samples stop is still released")
    func throttleReleasesTheHeldSample() {
        var throttle = ProgressThrottle()
        #expect(throttle.admit(ProgressSample(percent: 5, message: "a"), at: 0)?.percent == 5)
        #expect(throttle.admit(ProgressSample(percent: 60, message: "a"), at: 0.01) == nil)
        #expect(throttle.release(at: 0.02)?.percent == 60)
        #expect(throttle.release(at: 0.03) == nil)
    }

    @Test("a stage change passes at once and still advances the reported percent")
    func throttleLetsAStageChangeThrough() {
        var throttle = ProgressThrottle()
        #expect(throttle.admit(ProgressSample(percent: 30, message: "Downloading tiny"), at: 0)?.percent == 30)
        #expect(throttle.admit(ProgressSample(percent: 30, message: "Preparing audio"), at: 0.01)?.percent == 31)
    }

    // MARK: - Reporter

    @Test("the reporter drains every queued notification, in order, before finish returns")
    func reporterDrainsBeforeFinish() async throws {
        let log = NotificationLog()
        let reporter = ProgressReporter(token: .string("tok"), send: { log.append($0) })
        reporter.report(ProgressSample(percent: 10, message: "one"))
        reporter.report(ProgressSample(percent: 20, message: "two"))
        reporter.report(ProgressSample(percent: 30, message: "three"))
        await reporter.finish()

        let messages = try log.notifications.map { try progressMessage(in: $0) }
        #expect(messages == ["one", "two", "three"])
        let values = try log.notifications.map { try progressValue(in: $0) }
        #expect(values == [10, 20, 30])
    }

    @Test("the last sample of a burst reaches the client before finish returns")
    func reporterReportsTheLastSampleOfABurst() async throws {
        let log = NotificationLog()
        let reporter = ProgressReporter(token: .string("tok"), send: { log.append($0) })
        for percent in stride(from: 5, through: 95, by: 5) {
            reporter.report(ProgressSample(percent: percent, message: "Transcribing"))
        }
        await reporter.finish()

        let values = try log.notifications.map { try progressValue(in: $0) }
        #expect(values.first == 5)
        #expect(values.last == 95)
        #expect(values == values.sorted())
    }

    // MARK: - Single writer

    @Test("notifications reach stdout before their call's response")
    func notificationsPrecedeTheResponse() async throws {
        let bridge = GateBridge()
        let log = MessageLog()
        let dispatcher = RequestDispatcher(server: MCPServer(bridge: bridge), output: { log.append($0) })

        let task = await dispatcher.dispatch(toolCall(name: "parola_get_state", id: 1))
        await dispatcher.notify(progress(1), for: .int(1))
        await dispatcher.notify(progress(2), for: .int(1))
        await bridge.release()
        await task?.value

        #expect(log.kinds == ["notification", "notification", "response"])
    }

    @Test("a cancelled call writes no late notifications")
    func cancelledCallWritesNoNotifications() async throws {
        let bridge = GateBridge()
        let log = MessageLog()
        let dispatcher = RequestDispatcher(server: MCPServer(bridge: bridge), output: { log.append($0) })

        let task = await dispatcher.dispatch(toolCall(name: "parola_get_state", id: 1))
        await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: nil,
            method: "notifications/cancelled",
            params: AnyDecodable(["requestId": 1] as [String: Any])
        ))
        await dispatcher.notify(progress(1), for: .int(1))
        await bridge.release()
        await task?.value

        #expect(log.kinds.isEmpty)
    }

    @Test("a notification for a call that never ran is dropped")
    func unknownCallWritesNoNotifications() async throws {
        let log = MessageLog()
        let dispatcher = RequestDispatcher(server: MCPServer(bridge: GateBridge()), output: { log.append($0) })

        await dispatcher.notify(progress(1), for: .int(42))

        #expect(log.kinds.isEmpty)
    }

    // MARK: - Opt-in

    @Test("a transcribe with a progress token climbs to the end of the run")
    func transcribeWithATokenReportsProgress() async throws {
        let fixture = try await MockEngineFixture()
        defer { fixture.tearDown() }
        let log = NotificationLog()

        let response = try await fixture.server.handle(
            fixture.transcribeCall(id: 1, meta: #"{"progressToken":"tok-1"}"#),
            notify: { log.append($0) }
        )
        #expect(response != nil)

        let values = try log.notifications.map { try progressValue(in: $0) }
        #expect(!values.isEmpty)
        #expect(values == values.sorted())
        #expect(Set(values).count == values.count)
        #expect(values.last == 99)
        for notification in log.notifications {
            let params = try #require(try object(notification)["params"] as? [String: Any])
            #expect(params["progressToken"] as? String == "tok-1")
        }
    }

    @Test("the same transcribe without a token sends no notifications")
    func transcribeWithoutATokenSendsNothing() async throws {
        let fixture = try await MockEngineFixture()
        defer { fixture.tearDown() }
        let log = NotificationLog()

        let response = try await fixture.server.handle(
            fixture.transcribeCall(id: 1),
            notify: { log.append($0) }
        )
        #expect(response != nil)
        #expect(log.notifications.isEmpty)
    }

    // MARK: - Mapping

    @Test("progress keeps climbing from the download into the transcription")
    func mapClimbsAcrossPhases() {
        let map = TranscribeProgressMap(model: "openai_whisper-tiny", duration: 100, downloadsModel: true)
        let steps = [
            map.downloading(0).percent,
            map.downloading(0.5).percent,
            map.downloading(1).percent,
            map.entering(.preparingAudio).percent,
            map.entering(.transcribing).percent,
            map.transcribed(seconds: 50).percent,
            map.transcribed(seconds: 100).percent,
        ]
        #expect(steps == steps.sorted())
        #expect(Set(steps).count == steps.count)
        #expect(steps.last == 99)
    }

    @Test("a run that skips the download starts near zero")
    func mapWithoutDownload() {
        let map = TranscribeProgressMap(model: "openai_whisper-tiny", duration: 60, downloadsModel: false)
        #expect(map.entering(.preparingAudio).percent == 2)
        #expect(map.entering(.transcribing).percent == 5)
        #expect(map.transcribed(seconds: 30).percent == 52)
    }

    @Test("an unknown duration parks progress at the transcription floor")
    func mapWithoutDuration() {
        let map = TranscribeProgressMap(model: "openai_whisper-tiny", duration: nil, downloadsModel: false)
        #expect(map.transcribed(seconds: 12).percent == map.entering(.transcribing).percent)
    }

    // MARK: - Helpers

    private func callParams(meta: String?) throws -> [String: Any] {
        let metaField = meta.map { ",\"_meta\":\($0)" } ?? ""
        let raw = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"parola_transcribe","arguments":{}\(metaField)}}
        """
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(raw.utf8))
        return try #require(request.params?.value as? [String: Any])
    }

    private func toolCall(name: String, id: Int, meta: String? = nil) -> JSONRPCRequest {
        var params: [String: Any] = ["name": name, "arguments": [String: Any]()]
        if let meta, let decoded = try? JSONSerialization.jsonObject(with: Data(meta.utf8)) as? [String: Any] {
            params["_meta"] = decoded
        }
        return JSONRPCRequest(jsonrpc: "2.0", id: .int(id), method: "tools/call", params: AnyDecodable(params))
    }

    private func progress(_ value: Double) -> JSONRPCNotification {
        .progress(MCPProgressParams(progressToken: .int(1), progress: value, total: 100, message: "working"))
    }

    private func object(_ notification: JSONRPCNotification) throws -> [String: Any] {
        let data = try JSONEncoder().encode(notification)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func progressMessage(in notification: JSONRPCNotification) throws -> String {
        let params = try #require(try object(notification)["params"] as? [String: Any])
        return try #require(params["message"] as? String)
    }

    private func progressValue(in notification: JSONRPCNotification) throws -> Double {
        let params = try #require(try object(notification)["params"] as? [String: Any])
        return try #require(params["progress"] as? Double)
    }
}

/// Records what the dispatcher writes, synchronously, so ordering assertions stay exact.
private final class MessageLog: Sendable {
    private let entries = OSAllocatedUnfairLock<[JSONRPCMessage]>(initialState: [])

    func append(_ message: JSONRPCMessage) {
        entries.withLock { $0.append(message) }
    }

    var kinds: [String] {
        entries.withLock { $0 }.map { message in
            switch message {
            case .notification: "notification"
            case .response: "response"
            }
        }
    }
}

private final class NotificationLog: Sendable {
    private let entries = OSAllocatedUnfairLock<[JSONRPCNotification]>(initialState: [])

    func append(_ notification: JSONRPCNotification) {
        entries.withLock { $0.append(notification) }
    }

    var notifications: [JSONRPCNotification] {
        entries.withLock { $0 }
    }
}

/// A bridge whose `call` parks until `release()`, holding a tool call in flight.
private actor GateBridge: BridgeProtocol {
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var released = false

    func call(_ cmd: String, argsJSON: Data) async throws -> String {
        if released { return "{}" }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume(returning: "{}") }
        waiters.removeAll()
    }
}

private struct NullBridge: BridgeProtocol {
    func call(_ cmd: String, argsJSON: Data) async throws -> String { "{}" }
}

/// A server whose transcribe runs a mock engine over a real one-second file, so the progress path
/// runs end to end without a model on disk.
private struct MockEngineFixture {
    let server: MCPServer
    let audioURL: URL
    private let root: URL

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-mcp-progress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        audioURL = root.appendingPathComponent("input.wav")
        try Self.writeSilence(seconds: 1, to: audioURL)

        let registry = EngineRegistry()
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "ciao")],
            progressSeconds: (1...10).map { Double($0) / 10 },
            durationSeconds: 1,
            modelName: "openai_whisper-tiny"
        )
        await registry.register(engineID: .whisperKit, capabilities: .whisperKitDefaults) { _ in
            MockTranscriber.make(response: response, clock: ContinuousClock())
        }
        let modelStore = ModelStore(modelsDirectory: root)
        let installed = modelStore.installedURL(for: "openai_whisper-tiny")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        // Without a weights file the directory reads as a half-download and the session fetches the real model.
        try Data("weights".utf8).write(to: installed.appendingPathComponent("model.bin"))
        server = MCPServer(
            session: TranscriptionSession(modelStore: modelStore, registry: registry),
            modelStore: modelStore,
            libraryStore: LibraryStore(libraryURL: root.appending(path: "Library"), extraIndexer: nil),
            bridge: NullBridge()
        )
    }

    func transcribeCall(id: Int, meta: String? = nil) -> JSONRPCRequest {
        var params: [String: Any] = [
            "name": "parola_transcribe",
            "arguments": ["path": audioURL.path, "model": "openai_whisper-tiny"] as [String: Any],
        ]
        if let meta, let decoded = try? JSONSerialization.jsonObject(with: Data(meta.utf8)) as? [String: Any] {
            params["_meta"] = decoded
        }
        return JSONRPCRequest(jsonrpc: "2.0", id: .int(id), method: "tools/call", params: AnyDecodable(params))
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func writeSilence(seconds: Double, to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        let frames = AVAudioFrameCount(seconds * file.processingFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw MCPToolError("could not allocate a silent buffer")
        }
        buffer.frameLength = frames
        try file.write(from: buffer)
    }
}
