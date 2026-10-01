import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@Suite("Stage states")
struct StageStateTests {
    @Test("each session state has one Stage look")
    func modes() {
        #expect(StageMode.for(.arming(.countIn(remaining: 2)), isStreaming: false) == .countIn(2))
        #expect(StageMode.for(.arming(.preparingModel(name: "Whisper Turbo", download: 0.42)), isStreaming: true)
            == .preparing("Whisper Turbo", 0.42))
        #expect(StageMode.for(.arming(.startingCapture), isStreaming: false) == .starting)
        #expect(StageMode.for(.recording, isStreaming: true) == .live)
        #expect(StageMode.for(.paused(since: Date()), isStreaming: false) == .paused)
        #expect(StageMode.for(.finishing, isStreaming: false) == .finishing)
        #expect(StageMode.for(.transcribing(progress: 0.5), isStreaming: false) == .transcribing(0.5))
        #expect(StageMode.for(.done(entryID: "E"), isStreaming: false) == .landing)
        #expect(StageMode.for(.failed(message: "The microphone stopped."), isStreaming: false)
            == .failed("The microphone stopped."))
    }

    @Test("a session reads its own mode")
    func sessionMode() {
        var take = RecordingSession(
            takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .countIn(remaining: 3)
        )
        #expect(take.mode == .countIn(3))
        _ = take.markCapturing(at: Date())
        #expect(take.mode == .live)
    }
}
