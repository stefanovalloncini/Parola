import Foundation

/// A burn running in the background: the phase, the open transcript and the arrivals carry on around it.
struct BurnJob: Equatable, Identifiable {
    enum State: Equatable {
        case running(progress: Double)
        case finished
        case failed(message: String)
    }

    let id: UUID
    let output: URL
    var state: State

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var progress: Double? {
        if case .running(let progress) = state { return progress }
        return nil
    }
}
