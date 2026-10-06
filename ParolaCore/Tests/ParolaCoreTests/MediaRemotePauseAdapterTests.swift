import Foundation
import os
import Testing
@testable import ParolaCore

#if canImport(Darwin) && os(macOS)
import CoreAudio
#endif

@Suite("Media remote pause adapter")
struct MediaRemotePauseAdapterTests {
    private static let otherPID: pid_t = ProcessInfo.processInfo.processIdentifier &+ 1

    @Test("MediaRemote saying yes wins even with no other process outputting")
    func mediaRemoteWinsOverEmptyFallback() async {
        let adapter = MediaRemotePauseAdapter(nowPlayingQuery: { true }, outputActivityProbe: { [] })
        #expect(await adapter.isPlaying())
    }

    @Test("MediaRemote false and Parola's own PID running output only is not playing")
    func ownPIDRunningOutputOnlyIsNotPlaying() async {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let adapter = MediaRemotePauseAdapter(
            nowPlayingQuery: { false },
            outputActivityProbe: { [OutputProcess(pid: ownPID, isRunningOutput: true)] }
        )
        #expect(await adapter.isPlaying() == false)
    }

    @Test("MediaRemote false and another PID running output is playing")
    func anotherProcessRunningOutputIsPlaying() async {
        let adapter = MediaRemotePauseAdapter(
            nowPlayingQuery: { false },
            outputActivityProbe: { [OutputProcess(pid: Self.otherPID, isRunningOutput: true)] }
        )
        #expect(await adapter.isPlaying())
    }

    @Test("MediaRemote true wins without ever running the process probe")
    func mediaRemoteTrueShortCircuitsTheProbe() async {
        let probeCalls = OSAllocatedUnfairLock(initialState: 0)
        let adapter = MediaRemotePauseAdapter(
            nowPlayingQuery: { true },
            outputActivityProbe: {
                probeCalls.withLock { $0 += 1 }
                return []
            }
        )
        #expect(await adapter.isPlaying())
        #expect(probeCalls.withLock { $0 } == 0, "the probe must not run once MediaRemote already answered playing")
    }

    @Test("a process present but not running output does not count as playing")
    func nonOutputtingProcessDoesNotCount() {
        let processes = [OutputProcess(pid: Self.otherPID, isRunningOutput: false)]
        #expect(!MediaRemotePauseAdapter.otherProcessIsRunningOutput(in: processes))
    }

    @Test("an empty process list is not playing")
    func emptyListIsNotPlaying() {
        #expect(!MediaRemotePauseAdapter.otherProcessIsRunningOutput(in: []))
    }

    @Test("mixed processes: one other PID outputting among several is still playing")
    func oneOutputtingProcessAmongManyIsPlaying() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let processes = [
            OutputProcess(pid: ownPID, isRunningOutput: true),
            OutputProcess(pid: Self.otherPID, isRunningOutput: false),
            OutputProcess(pid: Self.otherPID &+ 1, isRunningOutput: true),
        ]
        #expect(MediaRemotePauseAdapter.otherProcessIsRunningOutput(in: processes))
    }

    #if canImport(Darwin) && os(macOS)
    private static let fixtureObjects: [AudioObjectID] = [1, 2, 3]

    @Test("a process whose PID read fails is skipped")
    func failedPIDReadIsSkipped() {
        let processes = MediaRemotePauseAdapter.outputProcesses(
            Self.fixtureObjects,
            pid: { object in object == 1 ? nil : pid_t(object) },
            isRunningOutput: { _ in true }
        )
        #expect(processes.map(\OutputProcess.pid).sorted() == [2, 3])
    }

    @Test("a process whose isRunningOutput read fails is skipped")
    func failedIsRunningOutputReadIsSkipped() {
        let processes = MediaRemotePauseAdapter.outputProcesses(
            Self.fixtureObjects,
            pid: { object in pid_t(object) },
            isRunningOutput: { object in object == 2 ? nil : false }
        )
        #expect(processes.map(\OutputProcess.pid).sorted() == [1, 3])
    }

    @Test("an unreadable process that would have been running output never counts as playing")
    func unreadableRunningProcessNeverCountsAsPlaying() {
        let processes = MediaRemotePauseAdapter.outputProcesses(
            [1],
            pid: { _ in nil },
            isRunningOutput: { _ in true }
        )
        #expect(processes.isEmpty)
        #expect(!MediaRemotePauseAdapter.otherProcessIsRunningOutput(in: processes))
    }

    @Test("Parola's own PID never counts, read through the full process-list helper")
    func ownPIDNeverCountsThroughOutputProcesses() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let processes = MediaRemotePauseAdapter.outputProcesses(
            [1],
            pid: { _ in ownPID },
            isRunningOutput: { _ in true }
        )
        #expect(!MediaRemotePauseAdapter.otherProcessIsRunningOutput(in: processes))
    }

    @Test("another outputting PID counts, read through the full process-list helper")
    func anotherPIDCountsThroughOutputProcesses() {
        let processes = MediaRemotePauseAdapter.outputProcesses(
            [1],
            pid: { _ in Self.otherPID },
            isRunningOutput: { _ in true }
        )
        #expect(MediaRemotePauseAdapter.otherProcessIsRunningOutput(in: processes))
    }
    #endif
}
