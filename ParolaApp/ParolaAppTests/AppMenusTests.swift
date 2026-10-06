import AppKit
import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("App menus: names and places")
struct AppMenusTests {
    private func makeModel(_ label: String, features: Set<ParolaFeature> = Set(ParolaFeature.allCases)) -> AppModel {
        AppModel(bootstrap: AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL(label),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: TestFilePicker(),
            enabledFeaturesOverride: features
        ))
    }

    /// The items AppKit builds from a menu's content, as the menu bar shows them.
    private func items<Content: View>(_ content: Content) -> [NSMenuItem] {
        let menu = NSHostingMenu(rootView: content)
        menu.update()
        return menu.items
    }

    private func titles<Content: View>(_ content: Content) -> [String] {
        items(content).map { $0.isSeparatorItem ? "—" : $0.title }
    }

    @Test("File holds the + menu's ways in, under the + menu's names")
    func fileMenuMatchesTheNewMenu() {
        let everything = titles(FileCommands(model: makeModel("file-menu")))
        #expect(everything == [
            "New Recording", "New System Audio Recording", "—",
            "Open Files…", "Transcribe Link…", "Batch Transcribe…", "Open Recent", "Save As Parola Document…",
        ])
        let plain = titles(FileCommands(model: makeModel("file-menu-plain", features: [])))
        #expect(plain == ["Open Files…", "Open Recent", "Save As Parola Document…"])
    }

    @Test("Check for Updates… sits under About Parola, off in a build with no update feed")
    func checkForUpdatesInTheAppMenu() throws {
        let appInfo = items(AppInfoCommands(showAbout: {}))
        #expect(appInfo.map(\.title) == ["About Parola", "Check for Updates…"])
        let check = try #require(appInfo.last)
        #expect(check.isEnabled == SparkleUpdater.feedURLConfigured)
    }

    @Test("Captions holds only Live Captions; Auto-Detect Language is a Transcript command, not an Edit one")
    func menusHoldWhatTheirNamesSay() {
        let model = makeModel("menu-places")
        let captions = titles(CaptionsCommands(model: model, liveCaptions: LiveCaptionsController()))
        #expect(!captions.contains("Start Dictation"), "\(captions)")
        #expect(!captions.contains("Show Scratchpad"), "\(captions)")
        #expect(captions.contains("Start Live Captions"), "\(captions)")
        let edit = titles(EditCommands(model: model))
        #expect(!edit.contains("Auto-Detect Language"), "\(edit)")
        let transcript = titles(TranscriptCommands(model: model))
        #expect(transcript.contains("Auto-Detect Language"), "\(transcript)")
    }

    @Test("the Playback menu shows Space, ⌘← and ⌘→ on Play, Skip Back and Skip Forward")
    func playbackMenuShowsItsKeys() {
        let playback = items(PlaybackCommands(model: makeModel("playback-keys"))).prefix(3)
        #expect(playback.map(\.title) == ["Play", "Skip Back 5 Seconds", "Skip Forward 5 Seconds"])
        #expect(playback.map(\.keyEquivalent) == [" ", String(UnicodeScalar(NSLeftArrowFunctionKey)!), String(UnicodeScalar(NSRightArrowFunctionKey)!)])
        #expect(playback.map(\.keyEquivalentModifierMask) == [[], [.command], [.command]])
    }

    @Test("a menu key the monitor leaves alone goes straight to its window, so a text field still gets its space")
    func unusedMenuKeySkipsTheMenu() throws {
        let model = makeModel("playback-keys-field")
        model.player = AVPlayer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = field
        window.makeFirstResponder(field)
        let space = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
        ))
        let passedOn = PlaybackKeyMonitor.route(space, window: window, model: model)
        #expect(passedOn == nil)
        #expect(field.string == " ")
        #expect(model.isPlaying == false)

        let letter = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
        ))
        let letterPassedOn = PlaybackKeyMonitor.route(letter, window: window, model: model)
        #expect(letterPassedOn === letter)
    }

    @Test("the releases page is the repository's")
    func releasesPage() {
        #expect(SupportLinks.releases.absoluteString == "https://github.com/stefanovalloncini/Parola/releases")
    }
}
