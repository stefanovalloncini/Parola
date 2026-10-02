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

    @Test("a source named by its own type gives the file it records to, as it does behind the protocol")
    @available(macOS 14.2, *)
    func inFlightURLByTypeAndByProtocol() async {
        let system = SystemAudioSource()
        let systemDirect = await system.inFlightURL()
        let systemErased: any LiveAudioSource = system
        let systemViaProtocol = await systemErased.inFlightURL()
        #expect(systemDirect != nil)
        #expect(systemDirect == systemViaProtocol)

        let tap = ProcessTapAudioSource(processObjects: [])
        let tapDirect = await tap.inFlightURL()
        let tapErased: any LiveAudioSource = tap
        let tapViaProtocol = await tapErased.inFlightURL()
        #expect(tapDirect != nil)
        #expect(tapDirect == tapViaProtocol)
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
