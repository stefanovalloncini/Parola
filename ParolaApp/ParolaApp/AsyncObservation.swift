import Foundation
import Observation

@MainActor
private final class AsyncObservationTickBox {
    var tick: (@MainActor () -> Void)?
}

@MainActor
enum AsyncObservation {
    static func changes<T: Sendable>(_ access: @escaping @MainActor () -> T) -> AsyncStream<T> {
        AsyncStream { continuation in
            let box = AsyncObservationTickBox()
            box.tick = { @MainActor in
                let value = withObservationTracking { access() } onChange: {
                    Task { @MainActor in box.tick?() }
                }
                continuation.yield(value)
            }
            Task { @MainActor in box.tick?() }
            continuation.onTermination = { _ in }
        }
    }
}
