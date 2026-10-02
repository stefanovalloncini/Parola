#if os(macOS)
import Foundation
import Testing
import os
@testable import ParolaCore

@Suite("System audio source")
struct SystemAudioSourceTests {
    private struct DisplayWentAway: Error {}

    @Test("a capture that ends by itself says so once, to a listener that asked before or after it ended")
    func captureThatEndsSaysSo() async {
        let heard = OSAllocatedUnfairLock(initialState: 0)
        let early = SystemAudioSource()
        await early.whenCaptureEnds { heard.withLock { $0 += 1 } }
        await early.captureEnded(DisplayWentAway())
        await early.captureEnded(DisplayWentAway())
        let once = heard.withLock { $0 }
        #expect(once == 1)

        let late = SystemAudioSource()
        await late.captureEnded(DisplayWentAway())
        await late.whenCaptureEnds { heard.withLock { $0 += 1 } }
        let twice = heard.withLock { $0 }
        #expect(twice == 2)
    }

    @Test("a capture asked to end says nothing when its stream stops after that")
    func stoppedCaptureSaysNothing() async {
        let heard = OSAllocatedUnfairLock(initialState: 0)
        let source = SystemAudioSource()
        await source.whenCaptureEnds { heard.withLock { $0 += 1 } }

        await source.cancel()
        await source.captureEnded(DisplayWentAway())

        let never = heard.withLock { $0 }
        #expect(never == 0)
    }
}
#endif
