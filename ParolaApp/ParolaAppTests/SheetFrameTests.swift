import AppKit
import SwiftUI
import Testing
@testable import Parola

@MainActor
@Suite("Sheet frame")
struct SheetFrameTests {
    private final class Calls {
        var closed = 0
        var cancelled = 0
        var confirmed = 0
    }

    private static let margin: CGFloat = 20

    private func element(_ leaf: String, in elements: [HostedAccessibility.Element]) throws -> HostedAccessibility.Element {
        let found = elements.first { $0.identifier?.hasSuffix(leaf) == true }
        return try #require(found, "no \(leaf)")
    }

    private func cancelAndConfirm(_ calls: Calls) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { calls.cancelled += 1 }
                .sheetSecondaryAction()
                .keyboardShortcut(.cancelAction)
                .axLeaf("Probe.Button.Cancel")
            Button("Save") { calls.confirmed += 1 }
                .sheetPrimaryAction()
                .keyboardShortcut(.defaultAction)
                .axLeaf("Probe.Button.Save")
        }
    }

    private func describedSheet(_ description: String) -> HostedWindow {
        let calls = Calls()
        let sheet = SheetFrame(title: "Burn subtitles into video", onClose: {}) {
            Text(verbatim: "Body").axLeaf("Probe.Text.Body")
        } footer: {
            cancelAndConfirm(calls)
        }
        .sheetDescription(Text(verbatim: description))
        .footerHasCancel()
        return HostedWindow(sheet, width: 480, height: 300)
    }

    @Test("the title is a heading, with no icon tile and no corner close button")
    func plainTitle() throws {
        let calls = Calls()
        let sheet = SheetFrame(title: "Burn subtitles into video", onClose: { calls.closed += 1 }) {
            Text(verbatim: "Body")
        } footer: {
            cancelAndConfirm(calls)
        }
        .footerHasCancel()
        let hosted = HostedWindow(sheet, width: 480, height: 260)
        defer { hosted.close() }
        let elements = HostedAccessibility.elements(in: hosted.host)
        let title = try element("Sheet.Text.Title", in: elements)
        #expect(title.role == "AXHeading")
        #expect(title.name == "Burn subtitles into video")
        let images = elements.filter { $0.role == NSAccessibility.Role.image.rawValue }
        #expect(images.isEmpty)
        let closeButtons = elements.filter { $0.name == "Close" }
        #expect(closeButtons.isEmpty)
    }

    @Test("a description sits between the title and the content, only when the sheet gives one")
    func descriptionUnderTheTitle() throws {
        let described = describedSheet("Captions are rendered permanently into a copy of the video.")
        let elements = HostedAccessibility.elements(in: described.host)
        described.close()
        let title = try element("Sheet.Text.Title", in: elements).frame
        let description = try element("Sheet.Text.Description", in: elements)
        let body = try element("Probe.Text.Body", in: elements).frame
        #expect(description.words == ["Captions are rendered permanently into a copy of the video."])
        #expect(description.frame.maxY <= title.minY)
        #expect(body.maxY <= description.frame.minY)
        #expect(abs(description.frame.minX - title.minX) < 0.5)

        let calls = Calls()
        let plain = SheetFrame(title: "Speakers", onClose: {}) {
            Text(verbatim: "Body")
        } footer: {
            cancelAndConfirm(calls)
        }
        .footerHasCancel()
        let hosted = HostedWindow(plain, width: 480, height: 300)
        defer { hosted.close() }
        let plainElements = HostedAccessibility.elements(in: hosted.host)
        let descriptions = plainElements.filter { $0.identifier?.hasSuffix("Sheet.Text.Description") == true }
        #expect(descriptions.isEmpty)
    }

    @Test("a long description stops at three lines")
    func descriptionIsCapped() throws {
        let short = describedSheet("One line.")
        let shortElements = HostedAccessibility.elements(in: short.host)
        short.close()
        let long = describedSheet(String(repeating: "A segment that keeps going and going. ", count: 30))
        let longElements = HostedAccessibility.elements(in: long.host)
        long.close()
        let line = try element("Sheet.Text.Description", in: shortElements).frame.height
        let capped = try element("Sheet.Text.Description", in: longElements).frame.height
        #expect(capped > line * 2)
        #expect(capped <= line * 3 + 1)
    }

    @Test("the title and the footer sit 20 pt in from the sheet's edges")
    func margins() throws {
        let calls = Calls()
        let sheet = SheetFrame(title: "Speakers", onClose: {}) {
            Text(verbatim: "Body")
        } footer: {
            cancelAndConfirm(calls)
        }
        .footerHasCancel()
        let hosted = HostedWindow(sheet, width: 480, height: 300)
        defer { hosted.close() }
        let edges = hosted.window.frame
        let elements = HostedAccessibility.elements(in: hosted.host)
        let title = try element("Sheet.Text.Title", in: elements).frame
        let save = try element("Probe.Button.Save", in: elements).frame
        #expect(abs(title.minX - edges.minX - Self.margin) < 0.5, "title starts \(title.minX - edges.minX) pt in")
        #expect(abs(edges.maxY - title.maxY - Self.margin) < 4, "title sits \(edges.maxY - title.maxY) pt down")
        #expect(abs(edges.maxX - save.maxX - Self.margin) < 0.5, "Save ends \(edges.maxX - save.maxX) pt in")
        #expect(abs(save.minY - edges.minY - Self.margin) < 0.5, "Save sits \(save.minY - edges.minY) pt up")
    }

    @Test("⎋ closes a sheet whose footer has no Cancel, through a button VoiceOver doesn't list")
    func escapeWithoutCancel() throws {
        let calls = Calls()
        let sheet = SheetFrame(title: "Manage People", onClose: { calls.closed += 1 }) {
            Text(verbatim: "Body")
        } footer: {
            Button("Done") { calls.confirmed += 1 }
                .sheetPrimaryAction()
                .keyboardShortcut(.defaultAction)
        }
        let hosted = HostedWindow(sheet, width: 460, height: 300)
        defer { hosted.close() }
        let escaped = hosted.press(.escape)
        #expect(escaped)
        #expect(calls.closed == 1)
        let elements = HostedAccessibility.elements(in: hosted.host)
        let closeButtons = elements.filter { $0.name == "Close" }
        #expect(closeButtons.isEmpty)
        let returned = hosted.press(.return)
        #expect(returned)
        #expect(calls.confirmed == 1)
    }

    @Test("a footer with its own Cancel gets ⎋ to itself, and ↩ is its default button")
    func escapeWithCancel() {
        let calls = Calls()
        let sheet = SheetFrame(title: "Speakers", onClose: { calls.closed += 1 }) {
            Text(verbatim: "Body")
        } footer: {
            cancelAndConfirm(calls)
        }
        .footerHasCancel()
        let hosted = HostedWindow(sheet, width: 480, height: 300)
        defer { hosted.close() }
        let escaped = hosted.press(.escape)
        #expect(escaped)
        #expect(calls.cancelled == 1)
        #expect(calls.closed == 0)
        let returned = hosted.press(.return)
        #expect(returned)
        #expect(calls.confirmed == 1)
    }
}
