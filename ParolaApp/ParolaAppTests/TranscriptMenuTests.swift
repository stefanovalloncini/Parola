import Foundation
import Testing
@testable import Parola

@Suite("Transcript and View menus")
struct TranscriptMenuTests {
    private func source(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/TranscriptMenuTests.swift",
            with: "ParolaApp/\(name).swift"
        )
        return try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("Jump to Time… and Show Outline open the header's popovers from the menu, with keys")
    func headerPopoversHaveMenuCommands() throws {
        let commands = try source("Views/AppCommands")
        #expect(commands.contains(#"Button("Jump to Time…") { model.jumpToTimeRequests &+= 1 } .keyboardShortcut("j", modifiers: [.command])"#))
        #expect(commands.contains(#"Button("Show Outline") { model.outlineRequests &+= 1 } .keyboardShortcut("o", modifiers: [.command, .shift])"#))
        let header = try source("Views/Transcript/TranscriptHeaderBar")
        #expect(header.contains(".onChange(of: model.jumpToTimeRequests) { _, _ in jumpOpen = true }"))
        #expect(header.contains(".onChange(of: model.outlineRequests) { _, _ in outlineOpen = true }"))
    }

    @Test("the display options are checked View menu items")
    func displayOptionsAreViewToggles() throws {
        let commands = try source("Views/AppCommands")
        #expect(commands.contains(#"Toggle("Compact Text", isOn: $model.transcriptCompact)"#))
        #expect(commands.contains(#"Toggle("Show Favorites Only", isOn: $model.favoritesOnly)"#))
        #expect(commands.contains(#"Toggle("Subtitle Warnings", isOn: $model.showSubtitleQC)"#))
    }
}
