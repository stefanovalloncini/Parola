import Foundation
import Testing
@testable import ParolaMCP

@Suite("RequestDispatcher per-request concurrency")
struct RequestDispatcherTests {
    @Test("a slow tools/call does not block other requests")
    func slowCallDoesNotBlockOthers() async throws {
        let gate = GatedBridge()
        let collector = OutputCollector()
        let dispatcher = makeDispatcher(bridge: gate, collector: collector)

        let slow = await dispatcher.dispatch(toolCall(name: "parola_get_state", id: 1))
        await dispatcher.dispatch(plain(method: "ping", id: 2))

        await collector.waitForResponses(1)
        #expect(await collector.hasResponse(for: .int(2)))
        #expect(await collector.hasResponse(for: .int(1)) == false)

        await gate.release()
        await collector.waitForResponses(2)
        #expect(await collector.hasResponse(for: .int(1)))
        await slow?.value
    }

    @Test("a cancelled request emits no response")
    func cancelledRequestEmitsNothing() async throws {
        let gate = GatedBridge()
        let collector = OutputCollector()
        let dispatcher = makeDispatcher(bridge: gate, collector: collector)

        let task = await dispatcher.dispatch(toolCall(name: "parola_get_state", id: 1))
        await dispatcher.dispatch(cancelNotification(requestId: 1))
        await task?.value

        #expect(await collector.hasResponse(for: .int(1)) == false)
    }

    @Test("cancelAll drops in-flight work")
    func cancelAllDropsInFlight() async throws {
        let gate = GatedBridge()
        let collector = OutputCollector()
        let dispatcher = makeDispatcher(bridge: gate, collector: collector)

        let task = await dispatcher.dispatch(toolCall(name: "parola_get_state", id: 1))
        await dispatcher.cancelAll()
        await task?.value

        #expect(await collector.hasResponse(for: .int(1)) == false)
    }

    @Test("shutdown fires onShutdown after its response is emitted")
    func shutdownFiresCallbackAfterResponse() async throws {
        let collector = OutputCollector()
        let dispatcher = RequestDispatcher(
            server: MCPServer(bridge: GatedBridge()),
            output: { response in Task { await collector.record(response) } },
            onShutdown: { Task { await collector.waitForResponses(1); await collector.recordShutdown() } }
        )

        let task = await dispatcher.dispatch(plain(method: "shutdown", id: 7))
        await task?.value
        await collector.waitForShutdown()

        let events = await collector.events
        #expect(events.count == 2)
        guard case .response(let response) = events.first else {
            Issue.record("first event was not a response")
            return
        }
        #expect(response.id == .int(7))
        guard case .shutdown = events.last else {
            Issue.record("last event was not the shutdown callback")
            return
        }
    }

    @Test("the parse-error emit path writes through the dispatcher")
    func parseErrorEmitPath() async throws {
        let collector = OutputCollector()
        let dispatcher = makeDispatcher(bridge: GatedBridge(), collector: collector)

        await dispatcher.emit(JSONRPCResponse.failure(
            id: .int(3),
            code: RPCErrorCode.parseError,
            message: "Parse error"
        ))
        await collector.waitForResponses(1)

        #expect(await collector.hasResponse(for: .int(3)))
    }

    private func makeDispatcher(bridge: any BridgeProtocol, collector: OutputCollector) -> RequestDispatcher {
        RequestDispatcher(
            server: MCPServer(bridge: bridge),
            output: { response in Task { await collector.record(response) } }
        )
    }

    private func toolCall(name: String, id: Int, arguments: [String: Any] = [:]) -> JSONRPCRequest {
        JSONRPCRequest(
            jsonrpc: "2.0",
            id: .int(id),
            method: "tools/call",
            params: AnyDecodable(["name": name, "arguments": arguments] as [String: Any])
        )
    }

    private func plain(method: String, id: Int) -> JSONRPCRequest {
        JSONRPCRequest(jsonrpc: "2.0", id: .int(id), method: method, params: nil)
    }

    private func cancelNotification(requestId: Int) -> JSONRPCRequest {
        JSONRPCRequest(
            jsonrpc: "2.0",
            id: nil,
            method: "notifications/cancelled",
            params: AnyDecodable(["requestId": requestId] as [String: Any])
        )
    }
}

/// A bridge whose `call` parks until `release()` and unwinds with `CancellationError` when its task is cancelled.
private actor GatedBridge: BridgeProtocol {
    private var waiters: [UUID: CheckedContinuation<String, Error>] = [:]
    private var settled: [UUID: Result<String, Error>] = [:]
    private var releasedValue: String?

    func call(_ cmd: String, argsJSON: Data) async throws -> String {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(id, continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release(_ value: String = "{}") {
        releasedValue = value
        for continuation in waiters.values { continuation.resume(returning: value) }
        waiters.removeAll()
    }

    private func register(_ id: UUID, _ continuation: CheckedContinuation<String, Error>) {
        if let result = settled.removeValue(forKey: id) {
            continuation.resume(with: result)
        } else if let value = releasedValue {
            continuation.resume(returning: value)
        } else {
            waiters[id] = continuation
        }
    }

    private func cancel(_ id: UUID) {
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        } else {
            settled[id] = .failure(CancellationError())
        }
    }
}

/// Records emitted responses (and the shutdown callback) in order, with continuation-based awaits.
private actor OutputCollector {
    enum Event: Sendable {
        case response(JSONRPCResponse)
        case shutdown
    }

    private var recorded: [Event] = []
    private var responseWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    var events: [Event] { recorded }

    func record(_ response: JSONRPCResponse) {
        recorded.append(.response(response))
        let count = responseCount
        var stillWaiting: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in responseWaiters {
            if count >= waiter.threshold { waiter.continuation.resume() }
            else { stillWaiting.append(waiter) }
        }
        responseWaiters = stillWaiting
    }

    func recordShutdown() {
        recorded.append(.shutdown)
        for continuation in shutdownWaiters { continuation.resume() }
        shutdownWaiters.removeAll()
    }

    func waitForResponses(_ count: Int) async {
        if responseCount >= count { return }
        await withCheckedContinuation { responseWaiters.append((threshold: count, continuation: $0)) }
    }

    func waitForShutdown() async {
        if recorded.contains(where: { if case .shutdown = $0 { return true }; return false }) { return }
        await withCheckedContinuation { shutdownWaiters.append($0) }
    }

    func hasResponse(for id: JSONRPCID) -> Bool {
        recorded.contains {
            if case .response(let response) = $0 { return response.id == id }
            return false
        }
    }

    private var responseCount: Int {
        recorded.reduce(into: 0) { count, event in
            if case .response = event { count += 1 }
        }
    }
}
