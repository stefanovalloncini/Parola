import AppKit
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

    @Test("on the Stage a held Space toggles the take once; its repeats are used up and change nothing")
    func stageSpaceRepeat() {
        let press = PlaybackKeyMonitor.action(keyCode: 49, modifiers: [], textInputActive: false, hasPlayer: true, stageShowsTake: true, isRepeat: false)
        let repeated = PlaybackKeyMonitor.action(keyCode: 49, modifiers: [], textInputActive: false, hasPlayer: true, stageShowsTake: true, isRepeat: true)
        #expect(press == .toggleTakePause)
        #expect(repeated == .swallowRepeat)
    }

    @Test("on the Stage, Space on a focused control presses the control, and never reaches the player")
    func stageSpaceOnAFocusedControl() {
        let action = PlaybackKeyMonitor.action(
            keyCode: 49, modifiers: [], textInputActive: false, hasPlayer: true, stageShowsTake: true, focusedControlTakesSpace: true
        )
        #expect(action == nil)
    }

    @Test("buttons and segmented controls take Space; lists, plain views and the window don't")
    @MainActor
    func controlsThatTakeSpace() {
        #expect(PlaybackKeyMonitor.takesSpace(NSButton()))
        #expect(PlaybackKeyMonitor.takesSpace(NSPopUpButton()))
        #expect(PlaybackKeyMonitor.takesSpace(NSSegmentedControl()))
        #expect(!PlaybackKeyMonitor.takesSpace(NSTableView()))
        #expect(!PlaybackKeyMonitor.takesSpace(NSOutlineView()))
        #expect(!PlaybackKeyMonitor.takesSpace(NSView()))
        #expect(!PlaybackKeyMonitor.takesSpace(nil))
    }

    @Test("off the Stage, Space plays or pauses with a control focused, the scrubber included")
    func spaceOnAFocusedScrubber() {
        let action = PlaybackKeyMonitor.action(
            keyCode: 49, modifiers: [], textInputActive: false, hasPlayer: true, focusedControlTakesSpace: true
        )
        #expect(action == .togglePlayPause)
    }

    @Test("in a viewer, Space and the skip keys drive the viewer's own player, not the main window's")
    @MainActor
    func viewerKeysDriveItsOwnPlayer() async throws {
        let model = EntryWindowTestSupport.makeModel("keys-viewer")
        let audio = try EntryWindowTestSupport.silentAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        let entry = try await EntryWindowTestSupport.seed(model, texts: ["alpha", "beta"], speakers: [nil, nil], audio: audio)
        let session = await EntryWindowTestSupport.openSession(model, entry)
        defer { model.releaseEntryWindow(session) }
        model.entryWindowKeyChanged(entry.id, isKey: true)
        #expect(model.player == nil)
        #expect(session.player != nil)

        let space = PlaybackKeyMonitor.handle(
            keyCode: 49, modifiers: [], firstResponder: nil, inMainWindow: false, model: model
        )
        let forward = PlaybackKeyMonitor.handle(
            keyCode: 124, modifiers: [.command], firstResponder: nil, inMainWindow: false, model: model
        )

        #expect(space)
        #expect(forward)
        #expect(session.currentTime > 0)
    }

    @Test("on the Stage, Space typed into the title stays text, and modified Space is not Pause")
    func stageSpaceLeavesTextAlone() {
        let typing = PlaybackKeyMonitor.action(keyCode: 49, modifiers: [], textInputActive: true, hasPlayer: true, stageShowsTake: true)
        let commandSpace = PlaybackKeyMonitor.action(keyCode: 49, modifiers: [.command], textInputActive: false, hasPlayer: false, stageShowsTake: true)
        #expect(typing == nil)
        #expect(commandSpace == nil)
    }

    private static func reading(
        _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], hasPlayer: Bool = false, text: Bool = false,
        stage: Bool = false, isRepeat: Bool = false, owns: Bool = true
    ) -> PlaybackKeyAction? {
        PlaybackKeyMonitor.action(
            keyCode: keyCode, modifiers: modifiers, textInputActive: text, hasPlayer: hasPlayer,
            stageShowsTake: stage, isRepeat: isRepeat, readingOwnsKeys: owns
        )
    }

    @Test("while reading owns the keys, Space toggles it even with no player, and with one")
    func readingSpace() {
        #expect(Self.reading(49) == .toggleReading)
        #expect(Self.reading(49, hasPlayer: true) == .toggleReading)
    }

    @Test("a held Space is swallowed after the first press")
    func readingSpaceRepeat() {
        #expect(Self.reading(49, isRepeat: true) == .swallowRepeat)
    }

    @Test("Command+Left is the previous sentence and Command+Right skips, with or without a player")
    func readingArrows() {
        #expect(Self.reading(123, [.command]) == .previousSentence)
        #expect(Self.reading(124, [.command], hasPlayer: true) == .skipSentence)
    }

    @Test("when reading does not own the keys, the player gets them as before")
    func playerKeepsKeys() {
        #expect(Self.reading(49, hasPlayer: true, owns: false) == .togglePlayPause)
        #expect(Self.reading(123, [.command], hasPlayer: true, owns: false) == .skipBack)
        #expect(Self.reading(124, [.command], hasPlayer: true, owns: false) == .skipForward)
        #expect(Self.reading(49, owns: false) == nil)
    }

    @Test("the Stage comes before reading, and a text input keeps its keys")
    func stageAndTextWin() {
        #expect(Self.reading(49, stage: true) == .toggleTakePause)
        #expect(Self.reading(49, text: true) == nil)
        #expect(Self.reading(123, [.command], text: true) == nil)
    }

    @Test("modified keys other than the arrows are not reading's")
    func otherModifiers() {
        #expect(Self.reading(49, [.command]) == nil)
        #expect(Self.reading(123) == nil)
        #expect(Self.reading(124, [.command, .shift]) == nil)
    }
}
