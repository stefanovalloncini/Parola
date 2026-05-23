import Foundation

public protocol TextPostProcessor: Sendable {
    func process(_ text: String) async -> String
}

struct PassThroughPostProcessor: TextPostProcessor {
    init() {}
    func process(_ text: String) async -> String { text }
}
