import Foundation

struct AutomationResponse: Encodable {
    let id: String
    let ok: Bool
    let command: String
    let result: AutomationValue?
    let error: AutomationError.Wire?
    let serverVersion: Int
    let elapsedMs: Int

    static func success(
        id: String,
        command: String,
        result: AutomationValue,
        serverVersion: Int,
        elapsedMs: Int
    ) -> AutomationResponse {
        AutomationResponse(
            id: id, ok: true, command: command,
            result: result, error: nil,
            serverVersion: serverVersion, elapsedMs: elapsedMs
        )
    }

    static func failure(
        id: String,
        command: String,
        error: AutomationError,
        serverVersion: Int,
        elapsedMs: Int
    ) -> AutomationResponse {
        AutomationResponse(
            id: id, ok: false, command: command,
            result: nil, error: error.wire,
            serverVersion: serverVersion, elapsedMs: elapsedMs
        )
    }
}

enum AutomationResponseEncoder {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    static func encode(_ response: AutomationResponse) -> Data {
        (try? encoder.encode(response)) ?? Data("{}".utf8)
    }
}
