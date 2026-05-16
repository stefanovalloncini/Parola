import Foundation

public protocol TextPostProcessor: Sendable {
    func process(_ text: String) async -> String
}

public struct PassThroughPostProcessor: TextPostProcessor {
    public init() {}
    public func process(_ text: String) async -> String { text }
}
