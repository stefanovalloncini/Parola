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
}
