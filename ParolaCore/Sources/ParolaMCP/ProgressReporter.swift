import Foundation
import ParolaCore

struct ProgressSample: Sendable {
    let percent: Int
    let message: String
}

/// Gates samples to one per whole percent and at most ten a second, letting a changed message
/// through at once. The admitted percent is bumped past the last one so it never repeats.
struct ProgressThrottle {
    static let minimumInterval: TimeInterval = 0.1

    private var lastPercent = -1
    private var lastMessage = ""
    private var lastSent: TimeInterval?

    mutating func admit(_ sample: ProgressSample, at now: TimeInterval) -> Int? {
        let changedMessage = sample.message != lastMessage
        guard changedMessage || sample.percent > lastPercent else { return nil }
        if !changedMessage, let lastSent, now - lastSent < Self.minimumInterval { return nil }
        let percent = max(sample.percent, lastPercent + 1)
        lastPercent = percent
        lastMessage = sample.message
        lastSent = now
        return percent
    }
}

/// The client's progress opt-in for one tool call: the token to echo and the sink to write to.
struct ProgressSink: Sendable {
    let token: ProgressToken
    let notify: @Sendable (JSONRPCNotification) async -> Void

    func reporter() -> ProgressReporter {
        ProgressReporter(token: token, send: notify)
    }
}

/// Turns one tool call's samples into ordered `notifications/progress`. The transcribe hooks are
/// synchronous and fire off-actor, so samples queue through a stream one pump drains, and `finish()`
/// waits for that drain — which is what keeps every notification ahead of the call's response.
struct ProgressReporter: Sendable {
    private let samples: AsyncStream<ProgressSample>.Continuation
    private let pump: Task<Void, Never>

    init(token: ProgressToken, send: @escaping @Sendable (JSONRPCNotification) async -> Void) {
        let (stream, continuation) = AsyncStream<ProgressSample>.makeStream()
        samples = continuation
        pump = Task {
            var throttle = ProgressThrottle()
            for await sample in stream {
                guard let percent = throttle.admit(sample, at: ProcessInfo.processInfo.systemUptime) else { continue }
                await send(.progress(MCPProgressParams(
                    progressToken: token,
                    progress: Double(percent),
                    total: 100,
                    message: sample.message
                )))
            }
        }
    }

    func report(_ sample: ProgressSample) {
        samples.yield(sample)
    }

    func finish() async {
        samples.finish()
        await pump.value
    }
}

/// One 0–100 scale for a transcribe run. A model download, when the run needs one, takes the
/// leading 30 points so the numbers keep climbing as the download rolls into the transcription.
struct TranscribeProgressMap: Sendable {
    let model: String
    let duration: Double?
    let downloadsModel: Bool

    func downloading(_ fraction: Double) -> ProgressSample {
        ProgressSample(
            percent: Int(Self.clamped(fraction) * Double(downloadCeiling)),
            message: "Downloading \(model)"
        )
    }

    func entering(_ stage: TranscribeStage) -> ProgressSample {
        switch stage {
        case .preparingAudio:
            ProgressSample(percent: downloadCeiling + 2, message: "Preparing audio")
        case .transcribing:
            ProgressSample(percent: transcribeFloor, message: transcribingMessage)
        }
    }

    func transcribed(seconds: Double) -> ProgressSample {
        guard let duration, duration > 0 else {
            return ProgressSample(percent: transcribeFloor, message: transcribingMessage)
        }
        let span = Double(Self.transcribeCeiling - transcribeFloor)
        let percent = transcribeFloor + Int(Self.clamped(seconds / duration) * span)
        return ProgressSample(percent: percent, message: transcribingMessage)
    }

    private static let transcribeCeiling = 99

    private var downloadCeiling: Int { downloadsModel ? 30 : 0 }
    private var transcribeFloor: Int { downloadCeiling + 5 }
    private var transcribingMessage: String { "Transcribing with \(model)" }

    private static func clamped(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
