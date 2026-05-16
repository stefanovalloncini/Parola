import Foundation

public protocol LanguageModel: Sendable {
    func respond(to prompt: String) async throws -> String
}
