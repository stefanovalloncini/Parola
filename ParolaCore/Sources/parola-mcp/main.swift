import Foundation
import ParolaMCP

let server = MCPServer()
let decoder = JSONDecoder()
let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func write(_ response: JSONRPCResponse) {
    do {
        var data = try encoder.encode(response)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    } catch {
        log("encode error: \(error)")
    }
}

log("parola-mcp listening on stdio")

let input = FileHandle.standardInput

while true {
    guard let line = readLine(strippingNewline: true) else {
        break
    }
    if line.isEmpty { continue }
    guard let data = line.data(using: .utf8) else { continue }

    let request: JSONRPCRequest
    do {
        request = try decoder.decode(JSONRPCRequest.self, from: data)
    } catch {
        let resp = JSONRPCResponse.failure(
            id: nil,
            code: RPCErrorCode.parseError,
            message: "Parse error: \(error.localizedDescription)"
        )
        write(resp)
        continue
    }

    let response = await server.handle(request)
    if let response {
        write(response)
    }
}

_ = input  // keep handle alive
