import Foundation

/// What Pause/Resume, Previous, Skip and Stop do for a reading's state; every surface that carries them reads this.
struct ReadingTransport: Equatable {
    enum Toggle: Equatable {
        case pause
        case resume
    }

    var toggle: Toggle
    var toggleEnabled: Bool
    var stepEnabled: Bool
    var stopEnabled: Bool

    var toggleTitle: String {
        switch toggle {
        case .pause: String(localized: "Pause Reading")
        case .resume: String(localized: "Resume Reading")
        }
    }

    static func resolve(state: ReadAloudController.State, blocked: ReadAloudController.BlockedReason?) -> ReadingTransport {
        switch state {
        case .preparing, .reading:
            ReadingTransport(toggle: .pause, toggleEnabled: true, stepEnabled: state == .reading && blocked == nil, stopEnabled: true)
        case .waiting, .paused:
            ReadingTransport(toggle: .resume, toggleEnabled: blocked == nil, stepEnabled: blocked == nil, stopEnabled: true)
        case .failed:
            ReadingTransport(toggle: .resume, toggleEnabled: false, stepEnabled: false, stopEnabled: true)
        case .idle, .noVoice:
            ReadingTransport(toggle: .pause, toggleEnabled: false, stepEnabled: false, stopEnabled: false)
        }
    }
}
