import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Main window")
struct MainWindowTests {
    private func source(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/MainWindowTests.swift",
            with: "ParolaApp/\(name).swift"
        )
        return try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("the model knows the main window while it is open and lets go of it once it closes")
    func reporterFollowsTheWindow() async {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("main-window"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Color.clear.background(MainWindowReporter(model: model)))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(model.mainWindow === window)

        window.close()
        let released = await waitUntil { model.mainWindow == nil }
        #expect(released)
    }

    @Test("the main window takes no tabs, so View ▸ Show Tab Bar can't open a second one over the same model")
    func mainWindowTakesNoTabs() {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("main-window-tabs"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        #expect(window.tabbingMode != .disallowed)

        window.contentView = NSHostingView(rootView: Color.clear.background(MainWindowReporter(model: model)))
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(window.tabbingMode == .disallowed)
        window.close()
    }

    @Test("from outside any scene, a closed main window opens again through the opener the scene handed over")
    func closedWindowOpensAgain() {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("main-window-reopen"))
        var opened = 0
        var activated = 0
        model.bindOpenMainWindow { opened += 1 }

        model.bringMainWindowForward(activate: { activated += 1 })

        #expect(activated == 1)
        #expect(opened == 1)
    }

    @Test("the main scene hands its opener to the model, and the menu bar's Open Parola goes through it")
    func openerIsBound() throws {
        #expect(try source("ParolaApp").contains(".bindsMainWindowOpening(to: model)"))
        #expect(try source("MenuBarController").contains("@objc private func openParola() { model?.bringMainWindowForward() }"))
    }

    @Test("File ▸ New Recording puts the main window in front, or opens it again, before the take starts")
    func newRecordingShowsTheMainWindowFirst() throws {
        let commands = try source("Views/AppCommands")
        #expect(commands.contains(#"Button("New Recording") { record(.microphone) }"#))
        #expect(commands.contains(#"Button("New System Audio Recording") { record(.systemAudio) }"#))
        #expect(commands.contains(
            "model.showMainWindow { openWindow(id: MainWindowScene.id) } model.startRecording(source: source)"
        ))
        #expect(try source("ParolaApp").contains("WindowGroup(id: MainWindowScene.id)"))
    }

    @Test("File ▸ Transcribe Link… and Add to Queue… put the main window in front, or open it again, as the + menu runs inside it")
    func fileIntakeShowsTheMainWindowFirst() throws {
        let commands = try source("Views/AppCommands")
        #expect(commands.contains(
            "Button(NewMenuCommand.transcribeLink.title) { model.showMainWindow { openWindow(id: MainWindowScene.id) } model.openLinkSheet(prefill: nil) }"
        ))
        #expect(commands.contains(
            "Button(NewMenuCommand.addToQueue.title) { model.showMainWindow { openWindow(id: MainWindowScene.id) } model.presentBatchOpenPanel() }"
        ))
    }

    @Test("the batch open panel's message has Italian")
    func batchOpenPanelMessageHasItalian() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        let key = "Select audio or video files to transcribe."
        #expect(italian.localizedString(forKey: key, value: "MISSING", table: nil) != "MISSING")
    }

    @Test("export blurbs, dictation style names and panel messages have Italian")
    func fx2StringsHaveItalian() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        let keys = [
            "Final Cut Pro project with the transcript as captions.",
            "Tab-separated rows, same columns as CSV.",
            "Voice",
            "Message",
            "Email",
            "Code",
            "Near field",
            "Compact pill next to the field you're dictating into.",
            "Pick an app to give it a custom dictation workflow.",
            "Choose a folder to watch for new audio and video files.",
            "Pick %@ again to refresh permissions.",
            "Save Parola settings",
            "Pick a .parola-settings file",
            "Export here",
        ]
        for key in keys {
            #expect(italian.localizedString(forKey: key, value: "MISSING", table: nil) != "MISSING", "\(key)")
        }
    }
}
