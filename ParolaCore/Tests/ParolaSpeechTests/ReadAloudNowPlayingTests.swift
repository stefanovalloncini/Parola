import Foundation
import MediaPlayer
import Testing
@testable import ParolaSpeech

@Suite("ReadAloudNowPlaying")
struct ReadAloudNowPlayingTests {
    @available(macOS 15, *)
    @Test("the info names the unit as a queue position and sets no duration or elapsed time")
    func info() {
        let info = ReadAloudNowPlaying.info(title: "Weekly · Notes", unitIndex: 4, unitCount: 40)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Weekly · Notes")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Parola")
        #expect(info[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.audio.rawValue)
        #expect(info[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? Int == 4)
        #expect(info[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int == 40)
        #expect(info[MPNowPlayingInfoPropertyExcludeFromSuggestions] as? Bool == true)
        #expect(info[MPMediaItemPropertyPlaybackDuration] == nil)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] == nil)
    }

    @Test("a handler built for a command routes that command to the main actor and returns its status")
    @MainActor
    func handlerOnMain() {
        let seen = Seen()
        for command in NowPlayingCommand.allCases {
            let handler = ReadAloudNowPlaying.handler(for: command) { received in
                seen.append(received)
                return received == .pause ? .commandFailed : .success
            }
            #expect(handler() == (command == .pause ? .commandFailed : .success))
        }
        #expect(seen.values == NowPlayingCommand.allCases)
    }

    @Test("a handler called from another thread hops to the main actor")
    func handlerOffMain() async {
        let handler = ReadAloudNowPlaying.handler(for: .next) { command in
            command == .next && Thread.isMainThread ? .success : .commandFailed
        }
        let status = await Task.detached { handler() }.value
        #expect(status == .success)
    }

    @Test("the recording fake records publications and withdrawals, and routes commands only while published")
    @MainActor
    func recording() {
        let nowPlaying = RecordingNowPlaying()
        let received = Seen()
        nowPlaying.onCommand = { command in
            received.append(command)
            return .success
        }
        #expect(nowPlaying.fire(.play) == .noActionableNowPlayingItem)
        nowPlaying.publish(title: "A", unitIndex: 0, unitCount: 3, isPlaying: true)
        nowPlaying.publish(title: "A", unitIndex: 1, unitCount: 3, isPlaying: false)
        #expect(nowPlaying.publications.map(\.unitIndex) == [0, 1])
        #expect(nowPlaying.publications.last?.isPlaying == false)
        #expect(nowPlaying.fire(.toggle) == .success)
        nowPlaying.withdraw()
        #expect(nowPlaying.fire(.next) == .noActionableNowPlayingItem)
        #expect(nowPlaying.withdrawCount == 1)
        #expect(received.values == [.toggle])
    }

    private final class Seen: Sendable {
        private let storage = Awaitable<[NowPlayingCommand]>([])
        var values: [NowPlayingCommand] { storage.value }
        func append(_ command: NowPlayingCommand) { storage.update { $0.append(command) } }
    }
}
