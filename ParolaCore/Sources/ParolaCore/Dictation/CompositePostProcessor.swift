import Foundation

public struct CompositePostProcessor: TextPostProcessor {
    public let processors: [any TextPostProcessor]

    public init(_ processors: [any TextPostProcessor]) {
        self.processors = processors
    }

    public func process(_ text: String) async -> String {
        var out = text
        for processor in processors {
            out = await processor.process(out)
        }
        return out
    }
}
