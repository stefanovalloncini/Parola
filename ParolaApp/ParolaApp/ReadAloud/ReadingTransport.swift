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
    var blockedMessage: String?

    var toggleTitle: String {
        switch toggle {
        case .pause: String(localized: "Pause Reading")
        case .resume: String(localized: "Resume Reading")
        }
    }

    static func resolve(
        state: ReadAloudController.State, blocked: ReadAloudController.BlockedReason?, sentenceStarted: Bool
    ) -> ReadingTransport {
        let message = blocked?.message
        let canStep = sentenceStarted && blocked == nil
        switch state {
        case .preparing, .reading:
            return ReadingTransport(
                toggle: .pause, toggleEnabled: true, stepEnabled: state == .reading && canStep, stopEnabled: true,
                blockedMessage: message
            )
        case .waiting, .paused:
            return ReadingTransport(
                toggle: .resume, toggleEnabled: blocked == nil, stepEnabled: canStep, stopEnabled: true, blockedMessage: message
            )
        case .failed:
            return ReadingTransport(
                toggle: .resume, toggleEnabled: false, stepEnabled: false, stopEnabled: true, blockedMessage: message
            )
        case .idle, .noVoice:
            return ReadingTransport(
                toggle: .pause, toggleEnabled: false, stepEnabled: false, stopEnabled: false, blockedMessage: nil
            )
        }
    }
}
