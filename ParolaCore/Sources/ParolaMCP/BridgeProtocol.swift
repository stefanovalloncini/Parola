import Foundation

public protocol BridgeProtocol: Sendable {
    func call(_ cmd: String, argsJSON: Data) async throws -> String
}
