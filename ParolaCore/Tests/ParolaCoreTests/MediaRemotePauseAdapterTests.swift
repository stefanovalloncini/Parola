import Foundation
import Testing
@testable import ParolaCore

@Suite("Media remote pause adapter")
struct MediaRemotePauseAdapterTests {
    private static let otherPID: pid_t = ProcessInfo.processInfo.processIdentifier &+ 1

    @Test("MediaRemote saying yes wins even with no other process outputting")
    func mediaRemoteWinsOverEmptyFallback() {
        #expect(MediaRemotePauseAdapter.decide(mediaRemoteSaysPlaying: true, processes: []))
    }

    @Test("MediaRemote saying yes wins even while only Parola's own PID outputs")
    func mediaRemoteWinsOverOwnPID() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let processes = [OutputProcess(pid: ownPID, isRunningOutput: true)]
        #expect(MediaRemotePauseAdapter.decide(mediaRemoteSaysPlaying: true, processes: processes))
    }

    @Test("Parola's own PID running output only is not playing")
    func ownPIDRunningOutputOnlyIsNotPlaying() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let processes = [OutputProcess(pid: ownPID, isRunningOutput: true)]
        #expect(!MediaRemotePauseAdapter.decide(mediaRemoteSaysPlaying: false, processes: processes))
    }

    @Test("another process running output is playing")
    func anotherProcessRunningOutputIsPlaying() {
        let processes = [OutputProcess(pid: Self.otherPID, isRunningOutput: true)]
        #expect(MediaRemotePauseAdapter.decide(mediaRemoteSaysPlaying: false, processes: processes))
    }

    // Stands in for a process whose properties failed to read too: the live probe omits
    // that process from its list entirely, so it never counts here either.
    @Test("a process present but not running output does not count as playing")
    func nonOutputtingProcessDoesNotCount() {
        let processes = [OutputProcess(pid: Self.otherPID, isRunningOutput: false)]
        #expect(!MediaRemotePauseAdapter.decide(mediaRemoteSaysPlaying: false, processes: processes))
    }

    @Test("an empty process list is not playing")
    func emptyListIsNotPlaying() {
        #expect(!MediaRemotePauseAdapter.decide(mediaRemoteSaysPlaying: false, processes: []))
    }

    @Test("mixed processes: one other PID outputting among several is still playing")
    func oneOutputtingProcessAmongManyIsPlaying() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let processes = [
            OutputProcess(pid: ownPID, isRunningOutput: true),
            OutputProcess(pid: Self.otherPID, isRunningOutput: false),
            OutputProcess(pid: Self.otherPID &+ 1, isRunningOutput: true),
        ]
        #expect(MediaRemotePauseAdapter.decide(mediaRemoteSaysPlaying: false, processes: processes))
    }

    // True either way the live MediaRemote query answers (it wins outright, or the fixture
    // probe does), so this stays deterministic however busy the machine running it is.
    @Test("isPlaying wires the injected probe through to the real async path")
    func isPlayingUsesInjectedProbe() async {
        let adapter = MediaRemotePauseAdapter(outputActivityProbe: {
            [OutputProcess(pid: Self.otherPID, isRunningOutput: true)]
        })
        #expect(await adapter.isPlaying())
    }
}
