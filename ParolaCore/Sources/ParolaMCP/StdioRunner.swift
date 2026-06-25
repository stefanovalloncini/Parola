import Darwin
import Foundation

/// Drives an `MCPServer` from line-delimited JSON-RPC over stdin/stdout.
public enum StdioRunner {
    public static func run(server: MCPServer = MCPServer()) async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let decoder = JSONDecoder()

        log("parola-mcp listening on stdio")

        installSignalHandlers()

        while !Task.isCancelled, await !server.shouldExit {
            guard let line = readLine(strippingNewline: true) else { break }
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8) else { continue }

            let request: JSONRPCRequest
            do {
                request = try decoder.decode(JSONRPCRequest.self, from: data)
            } catch {
                let envelopeID = Self.recoverRequestID(from: data)
                let resp = JSONRPCResponse.failure(
                    id: envelopeID,
                    code: RPCErrorCode.parseError,
                    message: "Parse error: \(error.localizedDescription)"
                )
                Self.write(resp, encoder: encoder)
                continue
            }

            do {
                if let response = try await server.handle(request) {
                    Self.write(response, encoder: encoder)
                }
            } catch is CancellationError {
                break
            } catch {
                let resp = JSONRPCResponse.failure(
                    id: request.id,
                    code: RPCErrorCode.internalError,
                    message: error.localizedDescription
                )
                Self.write(resp, encoder: encoder)
            }
        }
    }

    /// Second-pass parse so a malformed body still surfaces the envelope id, letting the client correlate the error.
    static func recoverRequestID(from data: Data) -> JSONRPCID? {
        struct Envelope: Decodable {
            let id: JSONRPCID?
        }
        return try? JSONDecoder().decode(Envelope.self, from: data).id
    }

    private static func write(_ response: JSONRPCResponse, encoder: JSONEncoder) {
        do {
            var data = try encoder.encode(response)
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        } catch {
            log("encode error: \(error)")
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Closes stdin on SIGINT/SIGTERM so `readLine` returns `nil` and the loop exits cleanly instead of aborting mid-write.
    private static func installSignalHandlers() {
        let handler: @convention(c) (Int32) -> Void = { _ in
            close(fileno(stdin))
        }
        signal(SIGINT, handler)
        signal(SIGTERM, handler)
    }
}
