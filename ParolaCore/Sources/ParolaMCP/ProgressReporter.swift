import Foundation
import ParolaCore

struct ProgressSample: Sendable {
    let percent: Int
    let message: String
}

/// Gates samples to one per whole percent and at most ten a second, letting a changed message through
/// at once. A sample inside the window is held, not dropped, so what goes out next is the newest
/// reading. The released percent is bumped past the last one so it never repeats.
struct ProgressThrottle {
    static let minimumInterval: TimeInterval = 0.1

    private var lastPercent = -1
    private var lastMessage = ""
    private var lastSent: TimeInterval?
    private var held: ProgressSample?

    mutating func admit(_ sample: ProgressSample, at now: TimeInterval) -> ProgressSample? {
        let changedMessage = sample.message != lastMessage
        guard changedMessage || sample.percent > lastPercent else { return nil }
        held = sample
        if !changedMessage, let lastSent, now - lastSent < Self.minimumInterval { return nil }
        return release(at: now)
    }

    mutating func release(at now: TimeInterval) -> ProgressSample? {
        guard let sample = held else { return nil }
        held = nil
        let percent = max(sample.percent, lastPercent + 1)
        lastPercent = percent
        lastMessage = sample.message
        lastSent = now
        return ProgressSample(percent: percent, message: sample.message)
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
            func emit(_ sample: ProgressSample) async {
                await send(.progress(MCPProgressParams(
                    progressToken: token,
                    progress: Double(sample.percent),
                    total: 100,
                    message: sample.message
                )))
            }
            var throttle = ProgressThrottle()
            for await sample in stream {
                guard let admitted = throttle.admit(sample, at: ProcessInfo.processInfo.systemUptime) else { continue }
                await emit(admitted)
            }
            // The run's last reading is usually still held, and the call's response follows immediately.
            if let last = throttle.release(at: ProcessInfo.processInfo.systemUptime) {
                await emit(last)
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
