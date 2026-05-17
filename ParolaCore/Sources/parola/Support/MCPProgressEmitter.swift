import Foundation

/// Emits MCP-shaped NDJSON progress on stderr and a single result block on stdout when `--mcp` is set.
public struct MCPProgressEmitter: Sendable {
    public enum Stage: String, Sendable {
        case downloading
        case loading
        case transcribing
        case exporting
        case finished
    }

    public let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }

    public func progress(_ stage: Stage, fraction: Double? = nil, detail: String? = nil) {
        guard enabled else { return }
        var payload: [String: Any] = [
            "type": "progress",
            "stage": stage.rawValue,
        ]
        if let fraction { payload["fraction"] = fraction }
        if let detail { payload["detail"] = detail }
        emit(payload, to: FileHandle.standardError)
    }

    public func result(text: String, isError: Bool = false) {
        guard enabled else { return }
        let payload: [String: Any] = [
            "content": [["type": "text", "text": text]],
            "isError": isError,
        ]
        emit(payload, to: FileHandle.standardOutput)
    }

    public func error(_ message: String) {
        result(text: message, isError: true)
    }

    private func emit(_ payload: [String: Any], to handle: FileHandle) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]) else { return }
        var out = data
        out.append(0x0A)
        handle.write(out)
    }
}
