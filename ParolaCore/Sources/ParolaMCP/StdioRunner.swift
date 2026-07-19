import Darwin
import Foundation

/// Drives an `MCPServer` from line-delimited JSON-RPC over stdin/stdout.
public enum StdioRunner {
    public static func run(server: MCPServer = MCPServer()) async {
        let decoder = JSONDecoder()

        log("parola-mcp listening on stdio")

        installSignalHandlers()

        // Closing stdin unblocks the reader after a shutdown response is written from a spawned
        // task; the same trick the signal handlers use ends the line sequence and exits the loop.
        let dispatcher = RequestDispatcher(
            server: server,
            output: Self.write,
            onShutdown: { close(fileno(stdin)) }
        )

        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard !Task.isCancelled, await !server.shouldExit else { break }
                if line.isEmpty { continue }
                guard let data = line.data(using: .utf8) else { continue }

                do {
                    let request = try decoder.decode(JSONRPCRequest.self, from: data)
                    await dispatcher.dispatch(request)
                } catch {
                    let envelopeID = Self.recoverRequestID(from: data)
                    await dispatcher.emit(JSONRPCResponse.failure(
                        id: envelopeID,
                        code: RPCErrorCode.parseError,
                        message: "Parse error: \(error.localizedDescription)"
                    ))
                }
            }
        } catch {
            // The line iterator throws EBADF once the signal handler closes stdin; treat as EOF.
        }

        await dispatcher.cancelAll()
    }

    /// Second-pass parse so a malformed body still surfaces the envelope id, letting the client correlate the error.
    static func recoverRequestID(from data: Data) -> JSONRPCID? {
        struct Envelope: Decodable {
            let id: JSONRPCID?
        }
        return try? JSONDecoder().decode(Envelope.self, from: data).id
    }

    private static func write(_ response: JSONRPCResponse) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        do {
            var data = try encoder.encode(response)
            data.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            log("write error: \(error)")
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Closes stdin on SIGINT/SIGTERM so the line sequence ends and the loop exits cleanly instead of aborting mid-write.
    private static func installSignalHandlers() {
        let handler: @convention(c) (Int32) -> Void = { _ in
            close(fileno(stdin))
        }
        signal(SIGINT, handler)
        signal(SIGTERM, handler)
        // A dead client closes stdout; writing to it raises SIGPIPE, which would crash instead of exit.
        signal(SIGPIPE, SIG_IGN)
    }
}
