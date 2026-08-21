import Foundation
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
        #expect(throttle.admit(ProgressSample(percent: 10, message: "a"), at: 0) == 10)
        #expect(throttle.admit(ProgressSample(percent: 10, message: "a"), at: 5) == nil)
        #expect(throttle.admit(ProgressSample(percent: 11, message: "a"), at: 5) == 11)
    }

    @Test("samples closer than the minimum interval are dropped")
    func throttleCapsTheRate() {
        var throttle = ProgressThrottle()
        #expect(throttle.admit(ProgressSample(percent: 1, message: "a"), at: 0) == 1)
        #expect(throttle.admit(ProgressSample(percent: 2, message: "a"), at: 0.05) == nil)
        #expect(throttle.admit(ProgressSample(percent: 3, message: "a"), at: 0.2) == 3)
    }

    @Test("a stage change passes at once and still advances the reported percent")
    func throttleLetsAStageChangeThrough() {
        var throttle = ProgressThrottle()
        #expect(throttle.admit(ProgressSample(percent: 30, message: "Downloading tiny"), at: 0) == 30)
        #expect(throttle.admit(ProgressSample(percent: 30, message: "Preparing audio"), at: 0.01) == 31)
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

    @Test("a tools/call without a progress token sends no notifications")
    func noTokenSendsNothing() async throws {
        let log = NotificationLog()
        let server = MCPServer(bridge: NullBridge())
        _ = try await server.handle(
            toolCall(name: "parola_transcribe", id: 1),
            notify: { log.append($0) }
        )
        #expect(log.notifications.isEmpty)
    }

    @Test("a tool with nothing to report sends no notifications even with a token")
    func tokenAloneSendsNothing() async throws {
        let log = NotificationLog()
        let server = MCPServer(bridge: NullBridge())
        _ = try await server.handle(
            toolCall(name: "parola_app_ping", id: 1, meta: #"{"progressToken":1}"#),
            notify: { log.append($0) }
        )
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
