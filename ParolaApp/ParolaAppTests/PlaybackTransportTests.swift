import Foundation
import Testing
@testable import Parola

@MainActor
@Suite("Playback transport")
struct PlaybackTransportTests {
    private func source(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/PlaybackTransportTests.swift",
            with: "ParolaApp/\(name).swift"
        )
        return try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("back and forward move 5 seconds, as the Playback menu and ⌘←/⌘→ do")
    func oneStepBothWays() {
        #expect(PlaybackSkip.back.seconds == -5)
        #expect(PlaybackSkip.forward.seconds == 5)
        #expect(PlaybackSkip.back.symbol == "gobackward.5")
        #expect(PlaybackSkip.forward.symbol == "goforward.5")
        #expect(PlaybackSkip.back.help == "Back 5 seconds (⌘←)")
        #expect(PlaybackSkip.forward.help == "Forward 5 seconds (⌘→)")
    }

    @Test("both windows' transports skip back and forward with the same buttons")
    func bothTransportsHaveBothButtons() throws {
        for file in ["Views/Transcript/MediaBar", "Windows/EntryViewerPlayback"] {
            let bar = try source(file)
            #expect(bar.contains("PlaybackSkipButton(skip: .back)"), "\(file)")
            #expect(bar.contains("PlaybackSkipButton(skip: .forward)"), "\(file)")
            #expect(!bar.contains("gobackward.15"), "\(file)")
        }
        let monitor = try source("PlaybackKeyMonitor")
        #expect(monitor.contains("model.skipInKeyWindow(by: PlaybackSkip.back.seconds)"))
        #expect(monitor.contains("model.skipInKeyWindow(by: PlaybackSkip.forward.seconds)"))
    }

    @Test("the scrubber steps 5 seconds and stays inside the media")
    func scrubberStepsWithinTheMedia() {
        #expect(ScrubberTrack.stepped(10, by: PlaybackSkip.forward.seconds, duration: 60) == 15)
        #expect(ScrubberTrack.stepped(58, by: PlaybackSkip.forward.seconds, duration: 60) == 60)
        #expect(ScrubberTrack.stepped(3, by: PlaybackSkip.back.seconds, duration: 60) == 0)
    }

    @Test("VoiceOver hears the playhead as a time of the whole")
    func scrubberSpeaksItsPosition() {
        #expect(ScrubberTrack.spokenPosition(progress: 723, duration: 2304) == "12:03 of 38:24")
    }

    @Test("the scrubber is one adjustable element that arrow keys move")
    func scrubberIsAdjustable() throws {
        let bar = try source("Views/Transcript/MediaBar")
        #expect(bar.contains(".accessibilityAdjustableAction { direction in"))
        #expect(bar.contains(#".accessibilityLabel(Text("Playback position"))"#))
        #expect(bar.contains(".onKeyPress(.leftArrow) { step(by: PlaybackSkip.back.seconds) }"))
        #expect(bar.contains(".onKeyPress(.rightArrow) { step(by: PlaybackSkip.forward.seconds) }"))
    }

    @Test("following the playhead or a search hit jumps under Reduce Motion")
    func followRespectsReduceMotion() {
        #expect(DS.Motion.follow(reduceMotion: true) == nil)
        #expect(DS.Motion.follow(reduceMotion: false) == DS.Motion.followSegment)
    }

    @Test("every transcript scroll that follows the playhead or a hit asks Reduce Motion first, in both windows")
    func everyFollowAsksReduceMotion() throws {
        let files = [
            "Views/Transcript/ContinuousTranscript", "Views/Transcript/SegmentsScroll",
            "Windows/EntryViewerContinuous", "Windows/EntryViewerTranscript",
        ]
        for file in files {
            let view = try source(file)
            #expect(view.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"), "\(file)")
            #expect(view.contains("withAnimation(DS.Motion.follow(reduceMotion: reduceMotion))"), "\(file)")
            #expect(!view.contains("withAnimation(.easeInOut(duration: 0.2))"), "\(file)")
        }
    }
}
