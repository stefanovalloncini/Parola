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
        #expect(monitor.contains("model.skip(by: PlaybackSkip.back.seconds)"))
        #expect(monitor.contains("model.skip(by: PlaybackSkip.forward.seconds)"))
    }
}
