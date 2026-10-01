import Testing
@testable import Parola

@Suite("Playback Key Monitor")
struct PlaybackKeyMonitorTests {
    @Test("Space toggles play/pause when player exists and no text input")
    func spaceTogglesWhenPlayerAndNoTextInput() {
        let action = PlaybackKeyMonitor.action(keyCode: 49, modifiers: [], textInputActive: false, hasPlayer: true)
        #expect(action == .togglePlayPause)
    }

    @Test("Space is ignored while typing")
    func spaceIgnoredWhileTyping() {
        let action = PlaybackKeyMonitor.action(keyCode: 49, modifiers: [], textInputActive: true, hasPlayer: true)
        #expect(action == nil)
    }

    @Test("Space is ignored without player")
    func spaceIgnoredWithoutPlayer() {
        let action = PlaybackKeyMonitor.action(keyCode: 49, modifiers: [], textInputActive: false, hasPlayer: false)
        #expect(action == nil)
    }

    @Test("Command+Left skips back, Command+Right skips forward")
    func commandArrowsSkip() {
        let skipBack = PlaybackKeyMonitor.action(keyCode: 123, modifiers: [.command], textInputActive: false, hasPlayer: true)
        let skipForward = PlaybackKeyMonitor.action(keyCode: 124, modifiers: [.command], textInputActive: false, hasPlayer: true)
        #expect(skipBack == .skipBack)
        #expect(skipForward == .skipForward)
    }

    @Test("Plain arrows and modified space are ignored")
    func plainArrowsAndModifiedSpaceIgnored() {
        let plainLeft = PlaybackKeyMonitor.action(keyCode: 123, modifiers: [], textInputActive: false, hasPlayer: true)
        let commandSpace = PlaybackKeyMonitor.action(keyCode: 49, modifiers: [.command], textInputActive: false, hasPlayer: true)
        #expect(plainLeft == nil)
        #expect(commandSpace == nil)
    }

    @Test("on the Stage, Space pauses the take, even with a transcript's player loaded")
    func spacePausesTheTakeOnTheStage() {
        let overPlayer = PlaybackKeyMonitor.action(keyCode: 49, modifiers: [], textInputActive: false, hasPlayer: true, stageShowsTake: true)
        let noPlayer = PlaybackKeyMonitor.action(keyCode: 49, modifiers: [], textInputActive: false, hasPlayer: false, stageShowsTake: true)
        #expect(overPlayer == .toggleTakePause)
        #expect(noPlayer == .toggleTakePause)
    }

    @Test("on the Stage, Space typed into the title stays text, and modified Space is not Pause")
    func stageSpaceLeavesTextAlone() {
        let typing = PlaybackKeyMonitor.action(keyCode: 49, modifiers: [], textInputActive: true, hasPlayer: true, stageShowsTake: true)
        let commandSpace = PlaybackKeyMonitor.action(keyCode: 49, modifiers: [.command], textInputActive: false, hasPlayer: false, stageShowsTake: true)
        #expect(typing == nil)
        #expect(commandSpace == nil)
    }
}
