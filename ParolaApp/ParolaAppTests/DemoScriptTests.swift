import Foundation
import Testing
@testable import Parola

@MainActor
@Suite("Introduction demo clip")
struct DemoScriptTests {

    private func clip(_ languages: [String]) throws -> DemoClip {
        try #require(DemoClip.bundled(preferredLanguages: languages, bundle: .main))
    }

    private func bothScripts() throws -> [DemoScript] {
        [try clip(["en-US"]).script, try clip(["it-IT"]).script]
    }

    @Test("both bundled clips decode")
    func bundledClipsDecode() throws {
        for script in try bothScripts() {
            #expect(!script.text.isEmpty)
            #expect(!script.speaker.isEmpty)
            #expect(script.words.count > 5)
            #expect(script.duration > 1)
            #expect(script.levelRate == 20)
        }
    }

    @Test("the words run forward and stay inside the clip")
    func wordsStayInsideTheClip() throws {
        for script in try bothScripts() {
            var previous = -1.0
            for word in script.words {
                #expect(word.start >= previous)
                #expect(word.start <= word.end)
                #expect(word.end <= script.duration + 0.25)
                previous = word.start
            }
        }
    }

    @Test("the level track covers the clip")
    func levelsCoverTheClip() throws {
        for script in try bothScripts() {
            let expected = script.duration * script.levelRate
            #expect(abs(Double(script.levels.count) - expected) <= 2)
            #expect(script.levels.allSatisfy { $0 >= 0 && $0 <= 1 })
        }
    }

    @Test("the reveal starts empty, follows the words and ends whole")
    func visibleWordCountFollowsTheClock() throws {
        for script in try bothScripts() {
            try #require(script.words.count > 3)
            #expect(script.visibleWordCount(at: -1) == 0)
            #expect(script.visibleWordCount(at: script.duration + 1) == script.words.count)
            #expect(script.visibleWordCount(at: script.words[3].start) == 4)
        }
    }

    @Test("the waveform window scrolls with the clip and pads the head with silence")
    func levelWindowScrolls() throws {
        for script in try bothScripts() {
            try #require(script.levels.count > 60)
            let opening = script.levels(window: 48, endingAt: 0)
            #expect(opening.count == 48)
            #expect(opening.dropLast().allSatisfy { $0 == 0 })
            #expect(opening.last == script.levels[0])

            let later = script.levels(window: 48, endingAt: 3)
            #expect(later.count == 48)
            #expect(later == Array(script.levels[(60 - 47)...60]))

            #expect(script.levels(window: 48, endingAt: -1).allSatisfy { $0 == 0 })
            #expect(script.levels(window: 48, endingAt: script.duration + 5).allSatisfy { $0 == 0 })
        }
    }

    @Test("the demo plays on the first visit only")
    func autoplaysOnce() {
        #expect(DemoPlayback.autoplays(hasPlayed: false, hasPlayer: true))
        #expect(!DemoPlayback.autoplays(hasPlayed: true, hasPlayer: true))
        #expect(!DemoPlayback.autoplays(hasPlayed: false, hasPlayer: false))
        #expect(!DemoPlayback.autoplays(hasPlayed: true, hasPlayer: false))
    }

    @Test("a fresh stage has a silent, unsettled clip ready")
    func freshPlayback() {
        let demo = DemoPlayback()
        #expect(demo.player != nil)
        #expect(!demo.hasPlayed)
        #expect(!demo.isSettled)
        #expect(demo.autoplays)
        #expect(demo.script.words.count > 5)
        demo.stop()
        #expect(!demo.isSettled)
    }

    @Test("a time outside the clip has no level")
    func levelOutsideTheClip() throws {
        for script in try bothScripts() {
            #expect(script.level(at: -1) == 0)
            #expect(script.level(at: script.duration + 5) == 0)
            #expect(script.level(at: script.duration / 2) >= 0)
        }
    }

    @Test("Italian readers get the Italian clip, everyone else the English one")
    func languagePick() throws {
        #expect(try clip(["it-IT"]).audioURL.lastPathComponent == "demo-it.m4a")
        #expect(try clip(["en-US"]).audioURL.lastPathComponent == "demo-en.m4a")
        #expect(try clip(["fr-FR"]).audioURL.lastPathComponent == "demo-en.m4a")
        #expect(try clip([]).audioURL.lastPathComponent == "demo-en.m4a")
    }

    @Test("the player opens the bundled clip and the mute chip drives its volume")
    func playerMutes() throws {
        for languages in [["en-US"], ["it-IT"]] {
            let player = try DemoPlayer(url: try clip(languages).audioURL)
            #expect(player.volume == 1)
            #expect(!player.isPlaying)
            #expect(!player.isFinished)
            player.isMuted = true
            #expect(player.volume == 0)
            player.isMuted = false
            #expect(player.volume == 1)
        }
    }
}
