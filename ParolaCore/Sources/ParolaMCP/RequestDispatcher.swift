import Foundation

/// Runs each JSON-RPC request on its own task so a long `tools/call` can't block the rest, while
/// funneling every response and notification through one actor-isolated write path to keep stdout serialized.
public actor RequestDispatcher {
    private let server: MCPServer
    private let output: @Sendable (JSONRPCMessage) -> Void
    private let onShutdown: @Sendable () -> Void
    private var inFlight: [JSONRPCID: Task<Void, Never>] = [:]

    public init(
        server: MCPServer,
        output: @escaping @Sendable (JSONRPCMessage) -> Void,
        onShutdown: @escaping @Sendable () -> Void = {}
    ) {
        self.server = server
        self.output = output
        self.onShutdown = onShutdown
    }

    @discardableResult
    public func dispatch(_ request: JSONRPCRequest) -> Task<Void, Never>? {
        if request.method == "notifications/cancelled" {
            cancel(request)
            return nil
        }
        let task = Task { await self.perform(request) }
        if let id = request.id {
            inFlight[id] = task
        }
        return task
    }

    public func emit(_ response: JSONRPCResponse) {
        // BridgeClient's blocking socket exchange ignores task cancellation, so a cancelled
        // request's handle() can return a stale result much later — that result must not be written.
        guard !Task.isCancelled else { return }
        output(.response(response))
    }

    /// Writes a progress notification only while its call is still in flight: the sender is an
    /// unstructured pump task, which never sees the cancellation of the request task it reports for.
    public func notify(_ notification: JSONRPCNotification, for id: JSONRPCID) {
        guard inFlight[id] != nil else { return }
        output(.notification(notification))
    }

    public func cancelAll() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    private func perform(_ request: JSONRPCRequest) async {
        defer { if let id = request.id { inFlight[id] = nil } }
        do {
            guard let response = try await server.handle(request, notify: notifier(for: request.id)) else { return }
            emit(response)
            if request.method == "shutdown" { onShutdown() }
        } catch is CancellationError {
            return
        } catch {
            emit(JSONRPCResponse.failure(
                id: request.id,
                code: RPCErrorCode.internalError,
                message: error.localizedDescription
            ))
        }
    }

    private func notifier(for id: JSONRPCID?) -> @Sendable (JSONRPCNotification) async -> Void {
        guard let id else { return { _ in } }
        return { [weak self] notification in await self?.notify(notification, for: id) }
    }

    private func cancel(_ request: JSONRPCRequest) {
        guard let id = Self.cancelTarget(request.params) else { return }
        inFlight.removeValue(forKey: id)?.cancel()
    }

    private static func cancelTarget(_ params: AnyDecodable?) -> JSONRPCID? {
        guard let object = params?.value as? [String: Any] else { return nil }
        if let value = object["requestId"] as? Int { return .int(value) }
        if let value = object["requestId"] as? String { return .string(value) }
        return nil
    }
}
